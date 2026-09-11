#!/usr/bin/env bash

# Vault Kubernetes Auth Setup Script for Minikube
# This script sets up HashiCorp Vault with Kubernetes authentication for testing Kroxylicious

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
VAULT_RELEASE="${VAULT_RELEASE:-vault}"
KROXYLICIOUS_NAMESPACE="${KROXYLICIOUS_NAMESPACE:-kroxylicious}"
KROXYLICIOUS_SA="${KROXYLICIOUS_SA:-kroxylicious-sa}"
VAULT_ROLE="${VAULT_ROLE:-kroxylicious-vault-role}"
POLICY_NAME="${POLICY_NAME:-kroxylicious_encryption_filter_policy}"
TEST_KEK="${TEST_KEK:-KEK-test-topic}"

# Logging functions
log_info() {
    printf "${BLUE}[INFO]${NC} %s\n" "$1"
}

log_success() {
    printf "${GREEN}[SUCCESS]${NC} %s\n" "$1"
}

log_warn() {
    printf "${YELLOW}[WARN]${NC} %s\n" "$1"
}

log_error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    local missing_tools=()
    
    for tool in kubectl helm minikube; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_error "Please install the missing tools and try again"
        exit 1
    fi
    
    # Check if minikube is running
    if ! minikube status &> /dev/null; then
        log_error "Minikube is not running. Please start it with: minikube start"
        exit 1
    fi
    
    log_success "All prerequisites met"
}

# Create namespaces
create_namespaces() {
    log_info "Creating namespaces..."
    kubectl create namespace "$VAULT_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace "$KROXYLICIOUS_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace kafka --dry-run=client -o yaml | kubectl apply -f -
    log_success "Namespaces created"
}

# Install Strimzi Kafka Operator
install_strimzi() {
    log_info "Installing Strimzi Kafka Operator..."
    
    local helm_output
    if helm_output=$(NO_COLOR=1 helm upgrade --install strimzi-operator oci://quay.io/strimzi-helm/strimzi-kafka-operator \
        --namespace kafka \
        --wait \
        --timeout 5m 2>&1); then
        log_success "Strimzi operator installed successfully"
    else
        log_error "Failed to install Strimzi operator"
        echo "$helm_output"
        exit 1
    fi
}

# Create Kafka cluster
create_kafka_cluster() {
    log_info "Creating Kafka cluster..."
    
    kubectl apply -f https://strimzi.io/examples/latest/kafka/kafka-single-node.yaml -n kafka
    
    log_info "Waiting for Kafka cluster to be ready..."
    kubectl wait kafka/my-cluster --for=condition=Ready --timeout=300s -n kafka
    
    log_success "Kafka cluster is ready"
}

# Install Vault via Helm
install_vault() {
    log_info "Installing Vault via Helm..."
    
    # Add HashiCorp Helm repository (suppress output)
    NO_COLOR=1 helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
    NO_COLOR=1 helm repo update >/dev/null 2>&1
    
    # Install Vault in dev mode for testing
    # Use NO_COLOR to prevent helm from outputting ANSI color codes
    local helm_output
    if helm_output=$(NO_COLOR=1 helm upgrade --install "$VAULT_RELEASE" hashicorp/vault \
        --namespace "$VAULT_NAMESPACE" \
        --set "server.dev.enabled=true" \
        --set "server.dev.devRootToken=root" \
        --set "injector.enabled=false" \
        --set "ui.enabled=true" \
        --set "server.service.type=ClusterIP" \
        --wait \
        --timeout 5m 2>&1); then
        log_success "Vault installed successfully"
    else
        log_error "Failed to install Vault"
        echo "$helm_output"
        exit 1
    fi
}

# Wait for Vault to be ready
wait_for_vault() {
    log_info "Waiting for Vault pod to be ready..."
    kubectl wait --for=condition=ready pod/vault-0 -n "$VAULT_NAMESPACE" --timeout=300s
    log_success "Vault is ready"
}

# Configure Transit Engine
configure_transit_engine() {
    log_info "Configuring Vault Transit Engine..."
    
    # Enable transit engine (ignore error if already enabled)
    kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- vault secrets enable transit 2>/dev/null || true
    
    log_success "Transit engine enabled"
}

# Create Vault policy for Kroxylicious
create_vault_policy() {
    log_info "Creating Vault policy for Kroxylicious..."
    
    # Create policy that allows Kroxylicious to use transit engine
    # Policy matches documentation: kroxylicious-docs/docs/_modules/record-encryption/hashicorp-vault/con-vault-setup.adoc
    kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "cat > /tmp/kroxylicious-policy.hcl <<EOF
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
    
    kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- vault policy write "$POLICY_NAME" /tmp/kroxylicious-policy.hcl
    
    log_success "Vault policy created"
}

# Create Kroxylicious ServiceAccount
create_kroxylicious_serviceaccount() {
    log_info "Creating Kroxylicious ServiceAccount..."
    
    kubectl create serviceaccount "$KROXYLICIOUS_SA" -n "$KROXYLICIOUS_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    
    log_success "ServiceAccount created"
}

# Create ClusterRoleBinding for Vault auth-delegator
create_vault_auth_delegator_binding() {
    log_info "Creating ClusterRoleBinding for Vault auth-delegator..."
    
    # This allows Vault to verify ServiceAccount tokens with the Kubernetes API
    kubectl create clusterrolebinding vault-auth-delegator \
        --clusterrole=system:auth-delegator \
        --serviceaccount="$VAULT_NAMESPACE:vault" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    log_success "ClusterRoleBinding created"
}

# Configure Kubernetes authentication in Vault
configure_kubernetes_auth() {
    log_info "Configuring Kubernetes authentication in Vault..."
    
    # Enable Kubernetes auth method (ignore error if already enabled)
    kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- vault auth enable kubernetes 2>/dev/null || true
    
    # Configure Kubernetes auth to use in-cluster Kubernetes API
    # Vault will use its own ServiceAccount token to authenticate to the K8s API
    kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- vault write auth/kubernetes/config \
        kubernetes_host="https://kubernetes.default.svc.cluster.local:443"
    
    log_success "Kubernetes auth configured"
}

# Create Vault role for Kroxylicious
create_vault_role() {
    log_info "Creating Vault role for Kroxylicious..."
    
    # Create role that binds the policy to the ServiceAccount
    kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- vault write "auth/kubernetes/role/$VAULT_ROLE" \
        bound_service_account_names="$KROXYLICIOUS_SA" \
        bound_service_account_namespaces="$KROXYLICIOUS_NAMESPACE" \
        policies="$POLICY_NAME" \
        ttl=24h 2>&1 | grep -v "^WARNING" || true
    
    log_success "Vault role created"
}

# Create test KEK
create_test_kek() {
    log_info "Creating test KEK ($TEST_KEK)..."
    
    # Create a test encryption key
    kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- vault write -f "transit/keys/$TEST_KEK"
    
    log_success "Test KEK created"
}

# Get Vault service information
get_vault_service_info() {
    log_info "Retrieving Vault service information..."
    
    # Get the Vault service cluster IP
    VAULT_SERVICE_IP=$(kubectl get svc vault -n "$VAULT_NAMESPACE" -o jsonpath='{.spec.clusterIP}')
    VAULT_SERVICE_URL="http://vault.$VAULT_NAMESPACE.svc.cluster.local:8200"
    
    log_success "Vault service: $VAULT_SERVICE_URL"
}

# Generate Kroxylicious configuration file
generate_kroxylicious_config() {
    local target="${1}"
    
    log_info "Generating Kroxylicious configuration file for '$target' mode..."
    
    local vault_url
    local token_path
    local config_comment
    local config_file="kroxylicious-kms-providers/kroxylicious-kms-provider-hashicorp-vault/target/kroxylicious-vault-k8s-auth-config.yaml"
    
    # Ensure target directory exists
    mkdir -p "$(dirname "$config_file")"
    
    if [[ "$target" == "local" ]]; then
        vault_url="http://localhost:8200/v1/transit"
        token_path="/tmp/sa-token.txt"
        config_comment="# Configuration for LOCAL testing (with port-forward)"
    else
        vault_url="http://vault.$VAULT_NAMESPACE.svc.cluster.local:8200/v1/transit"
        token_path="/var/run/secrets/kubernetes.io/serviceaccount/token"
        config_comment="# Configuration for IN-CLUSTER testing"
    fi
    
    cat > "$config_file" <<EOF
#
# Kroxylicious Configuration for Vault Kubernetes Auth
# Generated by: $0 setup $target
#
$config_comment
#

---
management:
  endpoints:
    prometheus: {}

virtualClusters:
  - name: demo
    targetCluster:
EOF

    if [[ "$target" == "local" ]]; then
        cat >> "$config_file" <<EOF
      bootstrapServers: localhost:9092
    gateways:
      - name: mygateway
        portIdentifiesNode:
          bootstrapAddress: localhost:9192
EOF
    else
        cat >> "$config_file" <<EOF
      bootstrapServers: my-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092
    gateways:
      - name: mygateway
        portIdentifiesNode:
          bootstrapAddress: kroxylicious.kroxylicious.svc.cluster.local:9192
EOF
    fi

    cat >> "$config_file" <<EOF
    logNetwork: false
    logFrames: false

filterDefinitions:
  - name: recordEncryption
    type: RecordEncryption
    config:
      kms: VaultKmsService
      kmsConfig:
EOF

    cat >> "$config_file" <<EOF
        vaultTransitEngineUrl: $vault_url
        
        credentials:
          kubernetes:
            role: $VAULT_ROLE
EOF
    if [[ "$target" == "local" ]]; then
        cat >> "$config_file" <<EOF
            serviceAccountTokenPath: $token_path
EOF
    fi
    cat >> "$config_file" <<EOF
            
            # Optional: Override default auth mount path
            # authPath: kubernetes
EOF

    cat >> "$config_file" <<EOF
      
      selector: TemplateKekSelector
      selectorConfig:
        template: "KEK-\$(topicName)"

defaultFilters:
  - recordEncryption
EOF
    
    log_success "Configuration file saved to: $config_file"
}

# Generate Kubernetes manifests for cluster deployment
generate_kubernetes_manifests() {
    local manifest_file="kroxylicious-kms-providers/kroxylicious-kms-provider-hashicorp-vault/target/kroxylicious-k8s-manifests.yaml"
    
    log_info "Generating Kubernetes manifests..."
    
    # Read the generated config file
    local config_content
    config_content=$(cat kroxylicious-kms-providers/kroxylicious-kms-provider-hashicorp-vault/target/kroxylicious-vault-k8s-auth-config.yaml)
    
    cat > "$manifest_file" <<'EOF'
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: kroxylicious-config
  namespace: kroxylicious
data:
  config.yaml: |
EOF
    
    # Indent the config content by 4 spaces
    echo "$config_content" | sed 's/^/    /' >> "$manifest_file"
    
    cat >> "$manifest_file" <<EOF

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kroxylicious
  namespace: kroxylicious
  labels:
    app: kroxylicious
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
      serviceAccountName: $KROXYLICIOUS_SA
      containers:
      - name: kroxylicious
        image: quay.io/kroxylicious/proxy:0.25.0-SNAPSHOT
        ports:
        - containerPort: 9192
          name: bootstrap
          protocol: TCP
        - containerPort: 9193
          name: broker-0
          protocol: TCP
        volumeMounts:
        - name: config
          mountPath: /opt/kroxylicious/config
          readOnly: true
        command:
        - /opt/kroxylicious/bin/kroxylicious-start.sh
        args:
        - --config
        - /opt/kroxylicious/config/config.yaml
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          capabilities:
            drop:
            - ALL
      volumes:
      - name: config
        configMap:
          name: kroxylicious-config
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault

---
apiVersion: v1
kind: Service
metadata:
  name: kroxylicious
  namespace: kroxylicious
  labels:
    app: kroxylicious
spec:
  type: ClusterIP
  ports:
  - port: 9192
    targetPort: 9192
    protocol: TCP
    name: bootstrap
  - port: 9193
    targetPort: 9193
    protocol: TCP
    name: broker-0
  selector:
    app: kroxylicious
EOF
    
    log_success "Kubernetes manifests saved to: $manifest_file"
}

# Print testing instructions
print_testing_instructions() {
    local target="${1}"
    local config_file="${2:-kroxylicious-kms-providers/kroxylicious-kms-provider-hashicorp-vault/target/kroxylicious-vault-k8s-auth-config.yaml}"
    
    # Reset terminal to ensure clean state
    printf '\033[0m'
    tput sgr0 2>/dev/null || true
    
    printf '\n'
    printf '\033[0;32m╔════════════════════════════════════════════════════════════════════════════╗\033[0m\n'
    printf '\033[0;32m║                    Vault Setup Complete!                                   ║\033[0m\n'
    printf '\033[0;32m╚════════════════════════════════════════════════════════════════════════════╝\033[0m\n'
    printf '\n'
    
    printf '\033[0;34mVault Information:\033[0m\n'
    printf '  Namespace:        %s\n' "$VAULT_NAMESPACE"
    printf '  Service:          vault.%s.svc.cluster.local:8200\n' "$VAULT_NAMESPACE"
    printf '  Root Token:       root (dev mode)\n'
    printf '  Transit Engine:   Enabled at /v1/transit\n'
    printf '  Test KEK:         %s\n' "$TEST_KEK"
    printf '\n'
    
    printf '\033[0;34mKubernetes Auth Configuration:\033[0m\n'
    printf '  Vault Role:       %s\n' "$VAULT_ROLE"
    printf '  ServiceAccount:   %s (namespace: %s)\n' "$KROXYLICIOUS_SA" "$KROXYLICIOUS_NAMESPACE"
    printf '  Policy:           %s\n' "$POLICY_NAME"
    printf '\n'
    
    # Show local testing instructions
    if [[ "$target" == "local" ]]; then
        printf '\033[0;34mTesting Locally (Outside Kubernetes):\033[0m\n'
        printf '\n'
        printf '\033[0;33mPrerequisite:\033[0m A Kafka cluster must be running on localhost:9092 (PLAIN listener)\n'
        printf '\n'
        printf '1. Port-forward Vault service (run in background):\n'
        printf '   \033[1;33mkubectl port-forward -n %s svc/vault 8200:8200 &\033[0m\n' "$VAULT_NAMESPACE"
        printf '\n'
        printf '2. Extract a ServiceAccount token:\n'
        printf '   \033[1;33mkubectl create token %s -n %s --duration=24h > /tmp/sa-token.txt\033[0m\n' "$KROXYLICIOUS_SA" "$KROXYLICIOUS_NAMESPACE"
        printf '\n'
        printf '3. Run Kroxylicious with the generated config (in background):\n'
        printf '   \033[1;33mkroxylicious-app/target/kroxylicious-app-*-bin/kroxylicious-app-*/bin/kroxylicious-start.sh \\\n'
        printf '     --config $config_file &\033[0m\n'
        printf '\n'
        printf '4. Test encryption by producing and consuming records:\n'
        printf '   \033[1;33m# Produce records through the proxy:\n'
        printf '   kafka-console-producer.sh --bootstrap-server localhost:9192 --topic test-topic\n'
        printf '   > Hello encrypted world\n'
        printf '   > This message is encrypted by Kroxylicious\n'
        printf '   > ^D (Ctrl+D to exit)\n'
        printf '\n'
        printf '   # Consume through proxy (records are decrypted):\n'
        printf '   kafka-console-consumer.sh --bootstrap-server localhost:9192 --topic test-topic --from-beginning\n'
        printf '   # You should see: "Hello encrypted world" and "This message is encrypted by Kroxylicious"\n'
        printf '   # ^C (Ctrl+C to exit)\n'
        printf '\n'
        printf '   # Consume directly from Kafka (records are encrypted - proves encryption works):\n'
        printf '   kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic test-topic --from-beginning\n'
        printf '   # You should see encrypted binary data (not readable text)\n'
        printf '   # This proves the records are encrypted at rest in Kafka\n'
        printf '   # ^C (Ctrl+C to exit)\033[0m\n'
        printf '\n'
    fi
    
    # Show cluster testing instructions
    if [[ "$target" == "cluster" ]]; then
        printf '\033[0;34mTesting in Kubernetes:\033[0m\n'
        printf '\n'
        printf '1. Deploy Kroxylicious using the generated manifests:\n'
        printf '   \033[1;33mkubectl apply -f kroxylicious-kms-providers/kroxylicious-kms-provider-hashicorp-vault/target/kroxylicious-k8s-manifests.yaml\033[0m\n'
        printf '\n'
        printf '2. Wait for Kroxylicious to be ready:\n'
        printf '   \033[1;33mkubectl wait --for=condition=ready pod -l app=kroxylicious -n %s --timeout=60s\033[0m\n' "$KROXYLICIOUS_NAMESPACE"
        printf '\n'
        printf '3. Verify Kroxylicious is running:\n'
        printf '   \033[1;33mkubectl logs -l app=kroxylicious -n %s --tail=20\033[0m\n' "$KROXYLICIOUS_NAMESPACE"
        printf '   \033[0;33m# Note: Vault authentication happens when first record arrives, not at startup\033[0m\n'
        printf '\n'
        printf '4. Test encryption by producing and consuming records:\n'
        printf '   \033[1;33m# Start a Kafka client pod:\n'
        printf '   kubectl run kafka-client --rm -i --tty --image=quay.io/strimzi/kafka:latest-kafka-4.3.0 -n kafka -- bash\n'
        printf '\n'
        printf '   # Inside the pod - Produce records through the proxy:\n'
        printf '   bin/kafka-console-producer.sh --bootstrap-server kroxylicious.kroxylicious.svc.cluster.local:9192 --topic test-topic\n'
        printf '   > Hello encrypted world\n'
        printf '   > This message is encrypted by Kroxylicious\n'
        printf '   > ^D (Ctrl+D to exit)\n'
        printf '\n'
        printf '   # Consume through proxy (records are decrypted):\n'
        printf '   bin/kafka-console-consumer.sh --bootstrap-server kroxylicious.kroxylicious.svc.cluster.local:9192 --topic test-topic --from-beginning\n'
        printf '   # You should see: "Hello encrypted world" and "This message is encrypted by Kroxylicious"\n'
        printf '   # ^C (Ctrl+C to exit)\n'
        printf '\n'
        printf '   # Consume directly from Kafka (records are encrypted - proves encryption works):\n'
        printf '   bin/kafka-console-consumer.sh --bootstrap-server my-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092 --topic test-topic --from-beginning\n'
        printf '   # You should see encrypted binary data (not readable text)\n'
        printf '   # This proves the records are encrypted at rest in Kafka\n'
        printf '   # ^C (Ctrl+C to exit)\033[0m\n'
        printf '\n'
    fi
    
    printf '\033[0;34mVerify Setup:\033[0m\n'
    printf '\n'
    printf '1. Check Vault status:\n'
    printf '   \033[1;33mkubectl exec -n %s vault-0 -- vault status\033[0m\n' "$VAULT_NAMESPACE"
    printf '\n'
    printf '2. List Kubernetes auth roles:\n'
    printf '   \033[1;33mkubectl exec -n %s vault-0 -- vault list auth/kubernetes/role\033[0m\n' "$VAULT_NAMESPACE"
    printf '\n'
    printf '3. Read the Kroxylicious role:\n'
    printf '   \033[1;33mkubectl exec -n %s vault-0 -- vault read auth/kubernetes/role/%s\033[0m\n' "$VAULT_NAMESPACE" "$VAULT_ROLE"
    printf '\n'
    printf '4. List Transit keys:\n'
    printf '   \033[1;33mkubectl exec -n %s vault-0 -- vault list transit/keys\033[0m\n' "$VAULT_NAMESPACE"
    printf '\n'
    
    if [[ "$target" == "local" ]]; then
        printf '\033[0;34mVerify Kubernetes Auth (Local):\033[0m\n'
        printf '\n'
        printf '1. Test JWT to Vault token exchange:\n'
        printf '   \033[1;33mVAULT_TOKEN=$(curl -s --request POST \\\n'
        printf '     --data '"'"'{"role": "%s", "jwt": "'"'"'$(cat /tmp/sa-token.txt)'"'"'"}'"'"' \\\n' "$VAULT_ROLE"
        printf '     http://localhost:8200/v1/auth/kubernetes/login | \\\n'
        printf '     jq -r '"'"'.auth.client_token'"'"')\n'
        printf '   \n'
        printf '   echo "Vault Token: $VAULT_TOKEN"\033[0m\n'
        printf '\n'
        printf '2. Test transit encryption with the token:\n'
        printf '   \033[1;33mexport VAULT_ADDR=http://localhost:8200\n'
        printf '   export VAULT_TOKEN  # Use token from step 1\n'
        printf '   \n'
        printf '   # List transit keys\n'
        printf '   vault list transit/keys\033[0m\n'
        printf '\n'
    fi
    
    printf '\033[0;34mCleanup:\033[0m\n'
    printf '   \033[1;33m%s cleanup\033[0m\n' "$0"
    if [[ "$target" == "local" ]]; then
        printf '   \033[0;33m# Note: Stop any background port-forward processes:\033[0m\n'
        printf '   \033[1;33m# pkill -f "kubectl port-forward.*vault"\033[0m\n'
    fi
    printf '\n'
    
    printf '\033[0;34mConfiguration File:\033[0m\n'
    printf '   \033[1;33m$config_file\033[0m\n'
    printf '\n'
}

# Setup function
setup() {
    local target="${1}"
    local config_file="kroxylicious-kms-providers/kroxylicious-kms-provider-hashicorp-vault/target/kroxylicious-vault-k8s-auth-config.yaml"
    
    if [[ -z "$target" ]]; then
        log_error "Target mode is required. Must be 'local' or 'cluster'"
        echo
        echo "Usage: $0 setup [local|cluster]"
        exit 1
    fi
    
    log_info "Starting Vault Kubernetes Auth setup for Minikube..."
    echo
    
    check_prerequisites
    create_namespaces
    
    # Install Kafka cluster for in-cluster testing
    if [[ "$target" == "cluster" ]]; then
        install_strimzi
        create_kafka_cluster
    fi
    
    install_vault
    wait_for_vault
    configure_transit_engine
    create_vault_policy
    create_kroxylicious_serviceaccount
    create_vault_auth_delegator_binding
    configure_kubernetes_auth
    create_vault_role
    create_test_kek
    get_vault_service_info
    generate_kroxylicious_config "$target"
    
    # Generate Kubernetes manifests for cluster mode
    if [[ "$target" == "cluster" ]]; then
        generate_kubernetes_manifests
    fi
    
    echo
    print_testing_instructions "$target" "$config_file"
}

# Cleanup function
cleanup() {
    log_info "Cleaning up Vault Kubernetes Auth setup..."
    echo
    
    # Delete Kafka cluster
    log_info "Deleting Kafka cluster..."
    kubectl delete -f https://strimzi.io/examples/latest/kafka/kafka-single-node.yaml -n kafka 2>/dev/null || log_warn "Kafka cluster not found or already deleted"
    
    # Wait for Kafka pods to terminate
    log_info "Waiting for Kafka pods to terminate..."
    kubectl wait --for=delete pod -l strimzi.io/cluster=my-cluster -n kafka --timeout=60s 2>/dev/null || true
    
    # Delete PVCs (this will also delete associated PVs)
    log_info "Deleting Kafka PVCs..."
    kubectl delete pvc -l strimzi.io/cluster=my-cluster -n kafka 2>/dev/null || log_warn "Kafka PVCs not found or already deleted"
    
    # Wait for PVCs to be fully deleted
    log_info "Waiting for PVCs to be deleted..."
    kubectl wait --for=delete pvc -l strimzi.io/cluster=my-cluster -n kafka --timeout=60s 2>/dev/null || true
    
    # Delete Strimzi operator
    log_info "Uninstalling Strimzi operator..."
    NO_COLOR=1 helm uninstall strimzi-operator -n kafka 2>/dev/null || log_warn "Strimzi operator not found or already deleted"
    
    # Delete Helm release (use NO_COLOR to prevent ANSI codes)
    log_info "Uninstalling Vault Helm release..."
    NO_COLOR=1 helm uninstall "$VAULT_RELEASE" -n "$VAULT_NAMESPACE" 2>/dev/null || log_warn "Vault release not found or already deleted"
    
    # Delete ServiceAccount
    log_info "Deleting Kroxylicious ServiceAccount..."
    kubectl delete serviceaccount "$KROXYLICIOUS_SA" -n "$KROXYLICIOUS_NAMESPACE" 2>/dev/null || log_warn "ServiceAccount not found or already deleted"
    
    # Delete ClusterRoleBinding
    log_info "Deleting ClusterRoleBinding..."
    kubectl delete clusterrolebinding vault-auth-delegator 2>/dev/null || log_warn "ClusterRoleBinding not found or already deleted"
    
    # Optionally delete namespaces (commented out by default to preserve other resources)
    # log_info "Deleting namespaces..."
    # kubectl delete namespace "$VAULT_NAMESPACE" 2>/dev/null || log_warn "Vault namespace not found or already deleted"
    # kubectl delete namespace "$KROXYLICIOUS_NAMESPACE" 2>/dev/null || log_warn "Kroxylicious namespace not found or already deleted"
    # kubectl delete namespace kafka 2>/dev/null || log_warn "Kafka namespace not found or already deleted"
    
    # Delete Kroxylicious deployment
    log_info "Deleting Kroxylicious deployment..."
    kubectl delete -f kroxylicious-kms-providers/kroxylicious-kms-provider-hashicorp-vault/target/kroxylicious-k8s-manifests.yaml 2>/dev/null || log_warn "Kroxylicious deployment not found or already deleted"
    
    # Delete generated files
    log_info "Deleting generated files..."
    rm -f kroxylicious-kms-providers/kroxylicious-kms-provider-hashicorp-vault/target/kroxylicious-vault-k8s-auth-config.yaml
    rm -f kroxylicious-kms-providers/kroxylicious-kms-provider-hashicorp-vault/target/kroxylicious-k8s-manifests.yaml
    
    echo
    log_success "Cleanup complete"
}

# Main script logic
case "${1:-}" in
    setup)
        target="${2:-}"
        if [[ "$target" != "local" && "$target" != "cluster" ]]; then
            echo "Error: Invalid or missing target. Must be 'local' or 'cluster'"
            echo
            echo "Usage: $0 setup [local|cluster]"
            exit 1
        fi
        setup "$target"
        ;;
    cleanup)
        cleanup
        ;;
    *)
        echo "Usage: $0 {setup [local|cluster]|cleanup}"
        echo
        echo "Commands:"
        echo "  setup [target]  - Install and configure Vault with Kubernetes auth"
        echo "                    target: 'local'   - Configure for local testing (requires local Kafka)"
        echo "                            'cluster' - Configure for in-cluster testing (installs Kafka)"
        echo "  cleanup         - Remove Vault and related resources"
        exit 1
        ;;
esac