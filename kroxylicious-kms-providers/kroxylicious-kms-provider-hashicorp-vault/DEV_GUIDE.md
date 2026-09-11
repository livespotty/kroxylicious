Here's some information that might be helpful when developing this module.

# Testing Kubernetes Authentication with Minikube

The HashiCorp Vault KMS provider supports Kubernetes ServiceAccount authentication, allowing Kroxylicious to authenticate to Vault using the pod's ServiceAccount token instead of static tokens.

## Automated Setup Script

The `scripts/vault-k8s-auth-minikube.sh` script provides automated setup and testing for Vault Kubernetes authentication in Minikube. It supports two modes:

### Local Mode
For developers testing locally (outside Kubernetes):
- Installs Vault in Minikube with Kubernetes auth configured
- Generates Kroxylicious configuration for local testing
- Extracts a ServiceAccount JWT from Kubernetes to use locally
- This mimics what would happen inside a pod (where the JWT is automatically mounted)
- Requires manual port-forwarding to access Vault
- Assumes Kafka is running on localhost:9092
- Provides step-by-step instructions for testing

```bash
./scripts/vault-k8s-auth-minikube.sh setup local
```

### Cluster Mode
For testing the complete in-cluster deployment:
- Installs Strimzi Kafka operator and single-node Kafka cluster
- Installs Vault with Kubernetes auth configured
- Generates Kubernetes manifests (ConfigMap, Deployment, Service)
- Generates Kroxylicious configuration for in-cluster testing
- Provides complete testing instructions with encryption verification

```bash
./scripts/vault-k8s-auth-minikube.sh setup cluster
```

Both modes:
- Create necessary namespaces, ServiceAccounts, and RBAC bindings
- Configure Vault Transit engine with appropriate policies
- Create a test KEK (Key Encryption Key)
- Generate configuration files in the module's `target/` directory
- Display comprehensive testing instructions

To remove all resources:
```bash
./scripts/vault-k8s-auth-minikube.sh cleanup
```

The script output includes all necessary commands and verification steps for testing encryption end-to-end.

## Quick Start for Off Cluster Testing

1. **Run the setup script** to install Vault in Minikube:
   ```bash
   ./scripts/vault-k8s-auth-minikube.sh setup
   ```

2. **Port-forward Vault** (in a separate terminal):
   ```bash
   kubectl port-forward -n vault svc/vault 8200:8200
   ```

3. **Extract a ServiceAccount token**:
   ```bash
   kubectl create token kroxylicious-sa -n kroxylicious --duration=24h > /tmp/sa-token.txt
   ```

4. **Create a Kroxylicious config** using Kubernetes auth:
   ```yaml
   virtualClusters:
     demo:
       targetCluster:
         bootstrap_servers: localhost:9092
       clusterNetworkAddressConfigProvider:
         type: PortPerBrokerClusterNetworkAddressConfigProvider
         config:
           bootstrapAddress: localhost:19092
   
   filters:
     - type: RecordEncryption
       config:
         kms: VaultKmsService
         kmsConfig:
           vaultTransitEngineUrl: http://localhost:8200/v1/transit
           role: "kroxylicious-vault-role"
           serviceAccountTokenPath: "/tmp/sa-token.txt"
         selector: TemplateKekSelector
         selectorConfig:
           template: "KEK_$(topicName)"
   ```

5. **Run Kroxylicious** with debug logging to see the authentication flow:
   ```bash
   KROXYLICIOUS_APP_LOG_LEVEL=DEBUG java -jar kroxylicious-app/target/kroxylicious-app-*-bin.tar.gz/kroxylicious-app-*/lib/kroxylicious-app-*.jar \
     --config config.yaml
   ```

6. **Create a test topic and send messages**:
   ```bash
   # Create topic (KEK will be auto-created in Vault)
   kafka-topics.sh --bootstrap-server localhost:19092 --create --topic test-topic --partitions 1 --replication-factor 1
   
   # Produce encrypted message
   echo "Hello World" | kafka-console-producer.sh --bootstrap-server localhost:19092 --topic test-topic
   
   # Consume decrypted message
   kafka-console-consumer.sh --bootstrap-server localhost:19092 --topic test-topic --from-beginning
   ```

7. **Observe the authentication flow** in the logs:
   ```
   DEBUG io.kroxylicious.kms.provider.hashicorp.vault.KubernetesTokenProvider - Reading Kubernetes ServiceAccount token from /tmp/sa-token.txt
   DEBUG io.kroxylicious.kms.provider.hashicorp.vault.KubernetesTokenProvider - Authenticating to Vault using Kubernetes auth with role kroxylicious-vault-role
   DEBUG io.kroxylicious.kms.provider.hashicorp.vault.KubernetesTokenProvider - Successfully obtained Vault token, expires at 2026-09-12T13:22:00Z
   DEBUG io.kroxylicious.kms.provider.hashicorp.vault.KubernetesTokenProvider - Scheduling token renewal in 82800000ms
   ```

## Testing in a Real Kubernetes Cluster

To test Kubernetes authentication in a real cluster (EKS, GKE, AKS, etc.):

### 1. Deploy Vault to Kubernetes

Install Vault using Helm:

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

# For production, use proper TLS and storage backend
helm install vault hashicorp/vault \
  --namespace vault \
  --create-namespace \
  --set "server.ha.enabled=true" \
  --set "server.ha.replicas=3" \
  --set "injector.enabled=false"
```

### 2. Initialize and Unseal Vault

```bash
# Initialize Vault (save the unseal keys and root token securely!)
kubectl exec -n vault vault-0 -- vault operator init

# Unseal each Vault pod
kubectl exec -n vault vault-0 -- vault operator unseal <unseal-key-1>
kubectl exec -n vault vault-0 -- vault operator unseal <unseal-key-2>
kubectl exec -n vault vault-0 -- vault operator unseal <unseal-key-3>
```

### 3. Configure Vault for Kubernetes Auth

```bash
# Enable Transit engine
kubectl exec -n vault vault-0 -- vault secrets enable transit

# Create policy for Kroxylicious
kubectl exec -n vault vault-0 -- sh -c "cat > /tmp/policy.hcl << 'EOF'
path \"transit/keys/KEK-*\" {
  capabilities = [\"read\"]
}
path \"transit/datakey/plaintext/KEK-*\" {
  capabilities = [\"update\"]
}
path \"transit/decrypt/KEK-*\" {
  capabilities = [\"update\"]
}
EOF"

kubectl exec -n vault vault-0 -- vault policy write kroxylicious_encryption_filter_policy /tmp/policy.hcl

# Enable Kubernetes auth
kubectl exec -n vault vault-0 -- vault auth enable kubernetes

# Configure Kubernetes auth
kubectl exec -n vault vault-0 -- vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443"

# Create Vault role bound to Kroxylicious ServiceAccount
kubectl exec -n vault vault-0 -- vault write auth/kubernetes/role/kroxylicious-vault-role \
  bound_service_account_names=kroxylicious-sa \
  bound_service_account_namespaces=kroxylicious \
  policies=kroxylicious_encryption_filter_policy \
  ttl=24h
```

### 4. Create Kubernetes Resources

```bash
# Create namespace
kubectl create namespace kroxylicious

# Create ServiceAccount
kubectl create serviceaccount kroxylicious-sa -n kroxylicious

# Grant Vault ServiceAccount permission to use TokenReview API
kubectl create clusterrolebinding vault-auth-delegator \
  --clusterrole=system:auth-delegator \
  --serviceaccount=vault:vault
```

### 5. Deploy Kroxylicious

Create a deployment using the ServiceAccount:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kroxylicious
  namespace: kroxylicious
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kroxylicious
  template:
    metadata:
      labels:
        app: kroxylicious
    spec:
      serviceAccountName: kroxylicious-sa
      containers:
      - name: kroxylicious
        image: quay.io/kroxylicious/kroxylicious:latest
        volumeMounts:
        - name: config
          mountPath: /opt/kroxylicious/config
      volumes:
      - name: config
        configMap:
          name: kroxylicious-config
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: kroxylicious-config
  namespace: kroxylicious
data:
  config.yaml: |
    virtualClusters:
      demo:
        targetCluster:
          bootstrap_servers: kafka.kafka.svc.cluster.local:9092
        clusterNetworkAddressConfigProvider:
          type: PortPerBrokerClusterNetworkAddressConfigProvider
          config:
            bootstrapAddress: kroxylicious.kroxylicious.svc.cluster.local:9192
    
    filters:
      - type: RecordEncryption
        config:
          kms: VaultKmsService
          kmsConfig:
            vaultTransitEngineUrl: https://vault.vault.svc.cluster.local:8200/v1/transit
            role: "kroxylicious-vault-role"
            # serviceAccountTokenPath defaults to /var/run/secrets/kubernetes.io/serviceaccount/token
            # authPath defaults to "kubernetes"
            tls:
              trust:
                insecureTls: false  # Use proper TLS in production
          selector: TemplateKekSelector
          selectorConfig:
            template: "KEK_$(topicName)"
```

### 6. Verify the Setup

```bash
# Check Kroxylicious logs
kubectl logs -n kroxylicious -l app=kroxylicious -f

# Verify Vault authentication
kubectl exec -n vault vault-0 -- vault list auth/kubernetes/role
kubectl exec -n vault vault-0 -- vault read auth/kubernetes/role/kroxylicious-vault-role

# Test with Kafka client
kubectl run kafka-client --rm -it --restart=Never --image=apache/kafka:latest -- \
  kafka-console-producer.sh --bootstrap-server kroxylicious.kroxylicious.svc.cluster.local:9192 --topic test
```

## Testing Token Renewal

The Kubernetes token provider automatically renews Vault tokens before they expire. To test this:

1. **Configure a short TTL** for the Vault role:
   ```bash
   kubectl exec -n vault vault-0 -- vault write auth/kubernetes/role/kroxylicious-vault-role \
     bound_service_account_names=kroxylicious-sa \
     bound_service_account_namespaces=kroxylicious \
     policies=kroxylicious_encryption_filter_policy \
     ttl=5m
   ```

2. **Enable debug logging** in Kroxylicious to see renewal activity:
   ```yaml
   # In your config or via environment variable
   KROXYLICIOUS_APP_LOG_LEVEL=DEBUG
   ```

3. **Observe the logs** for renewal messages:
   ```
   DEBUG io.kroxylicious.kms.provider.hashicorp.vault.KubernetesTokenProvider - Vault token will expire at 2026-09-11T13:27:00Z
   DEBUG io.kroxylicious.kms.provider.hashicorp.vault.KubernetesTokenProvider - Scheduling token renewal in 240000ms (80% of TTL)
   DEBUG io.kroxylicious.kms.provider.hashicorp.vault.KubernetesTokenProvider - Renewing Vault token
   DEBUG io.kroxylicious.kms.provider.hashicorp.vault.KubernetesTokenProvider - Successfully renewed Vault token, new expiry 2026-09-11T13:32:00Z
   ```

## Testing with Static Tokens (for comparison)

To compare Kubernetes auth with static token authentication:

```yaml
filters:
  - type: RecordEncryption
    config:
      kms: VaultKmsService
      kmsConfig:
        vaultTransitEngineUrl: http://vault.vault.svc.cluster.local:8200/v1/transit
        vaultToken:
          password: "hvs.CAESIF..."  # Static token
          # OR
          passwordFile: "/path/to/token/file"
      selector: TemplateKekSelector
      selectorConfig:
        template: "KEK_$(topicName)"
```

## Troubleshooting

### Authentication Failures

1. **Check ServiceAccount exists**:
   ```bash
   kubectl get sa kroxylicious-sa -n kroxylicious
   ```

2. **Verify ClusterRoleBinding**:
   ```bash
   kubectl get clusterrolebinding vault-auth-delegator -o yaml
   ```

3. **Check Vault role configuration**:
   ```bash
   kubectl exec -n vault vault-0 -- vault read auth/kubernetes/role/kroxylicious-vault-role
   ```

4. **Verify Vault can reach Kubernetes API**:
   ```bash
   kubectl exec -n vault vault-0 -- vault write auth/kubernetes/config \
     kubernetes_host="https://kubernetes.default.svc:443"
   ```

### Token Expiration Issues

If tokens expire unexpectedly:

1. **Check token TTL** in the Vault role:
   ```bash
   kubectl exec -n vault vault-0 -- vault read auth/kubernetes/role/kroxylicious-vault-role
   ```

2. **Verify renewal is happening** in Kroxylicious logs:
   ```bash
   kubectl logs -n kroxylicious -l app=kroxylicious | grep "token renewal"
   ```

3. **Check for clock skew** between Vault and Kroxylicious pods

### Network Connectivity

If Kroxylicious can't reach Vault:

1. **Test connectivity** from Kroxylicious pod:
   ```bash
   kubectl exec -n kroxylicious <pod-name> -- curl -v http://vault.vault.svc.cluster.local:8200/v1/sys/health
   ```

2. **Check NetworkPolicies** that might block traffic

3. **Verify DNS resolution**:
   ```bash
   kubectl exec -n kroxylicious <pod-name> -- nslookup vault.vault.svc.cluster.local
   ```

## Security Considerations

### Production Deployment

For production deployments:

1. **Use TLS** for Vault communication:
   ```yaml
   kmsConfig:
     vaultTransitEngineUrl: https://vault.vault.svc.cluster.local:8200/v1/transit
     tls:
       trust:
         storeFile: /path/to/truststore.jks
         storePassword: changeit
         storeType: JKS
   ```

2. **Use proper Vault storage backend** (Consul, Raft, etc.) instead of dev mode

3. **Enable Vault audit logging**:
   ```bash
   kubectl exec -n vault vault-0 -- vault audit enable file file_path=/vault/logs/audit.log
   ```

4. **Implement least-privilege policies** - only grant the minimum permissions needed

5. **Rotate ServiceAccount tokens** regularly

6. **Monitor token renewal** and set up alerts for failures

7. **Use Vault namespaces** for multi-tenancy if needed

### Token Lifecycle

- ServiceAccount tokens are automatically mounted at `/var/run/secrets/kubernetes.io/serviceaccount/token`
- Kubernetes rotates these tokens periodically (default: 1 hour)
- Kroxylicious reads the token file on each authentication attempt, picking up rotations automatically
- Vault tokens obtained via Kubernetes auth have a configurable TTL (default: 24h in examples)
- Kroxylicious renews Vault tokens at 80% of their TTL

## Integration Tests

The module includes integration tests that verify Kubernetes authentication:

```bash
# Run integration tests
mvn verify -pl kroxylicious-kms-provider-hashicorp-vault -Pintegration-tests

# Run specific Kubernetes auth test
mvn verify -pl kroxylicious-kms-provider-hashicorp-vault -Pintegration-tests -Dit.test=VaultKmsKubernetesAuthIT
```

The test uses Testcontainers to:
- Start a Vault container
- Mock the Kubernetes API (OIDC discovery, JWKS, TokenReview)
- Generate a valid ServiceAccount JWT
- Configure Vault Kubernetes auth
- Verify Kroxylicious can authenticate and perform KEK operations

## References

- [HashiCorp Vault Kubernetes Auth](https://developer.hashicorp.com/vault/docs/auth/kubernetes)
- [Vault Transit Engine](https://developer.hashicorp.com/vault/docs/secrets/transit)
- [Kubernetes TokenReview API](https://kubernetes.io/docs/reference/kubernetes-api/authentication-resources/token-review-v1/)
- [Kroxylicious Record Encryption](https://kroxylicious.io/kroxylicious/)
