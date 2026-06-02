# aws-load-balancer-controller

**AUTHORED ONLY — not run from this repo.** The scenarios referenced here are
authored and validated via `kubectl --dry-run=client` and `yamllint` against a
local kind cluster. No `kubectl apply`, `helm install`, or `aws` invocation
targets a real EKS cluster from this repository. Apply them yourself to your
own EKS cluster.

## What

The AWS Load Balancer Controller (LBC) provisions AWS Application Load
Balancers (ALBs) and Network Load Balancers (NLBs) from Kubernetes Ingress
and Service resources. It replaces the legacy in-tree AWS cloud provider
controller and supports advanced routing, TLS termination via AWS Certificate
Manager (ACM), IP target mode for VPC CNI, and Gateway API integration.

Key capabilities:

- **ALB Ingress** — provisions an Application Load Balancer from a
  `networking.k8s.io/v1 Ingress` resource, with host/path routing, TLS
  termination via ACM certificates, WAF integration, and IP or instance
  target mode.
- **NLB Service** — provisions a Network Load Balancer from a `Service` of
  type `LoadBalancer`, with cross-zone load balancing, static EIPs, and
  PROXY protocol support.
- **Gateway API** — provisions ALBs from `Gateway` and `HTTPRoute` resources
  (v2.8+ with Gateway API CRDs installed).

These capabilities are EKS-specific. They cannot be exercised on kind or
minikube because they depend on AWS infrastructure (VPC, ALB/NLB, ACM, IAM).
The scenarios authored for this integration are **design-only** — they serve
as reference implementations that a user ships to their own EKS cluster.

## Target Kubernetes version

EKS 1.28+ (AWS Load Balancer Controller v2.8+ requires EKS 1.22+; Gateway
API support requires EKS 1.25+ and Gateway API CRDs).

All scenario YAMLs authored under `networking/ingress-lb/` carry an annotation
`chart-test-swarm/target-k8s-version: eks-1.30` to pin the expected Kubernetes
API version.

## When

Use AWS Load Balancer Controller scenarios when the Helm chart under test:

- Must be exposed through an AWS Application Load Balancer with host-based
  routing, path-based routing, TLS termination via ACM, or WAF integration.
- Requires a Network Load Balancer for TCP/UDP workloads (gRPC, game servers,
  legacy protocols) with static EIPs.
- Uses Gateway API and expects the LBC to provision ALBs from `Gateway` and
  `HTTPRoute` resources.
- Must prove that Ingress annotations (`alb.ingress.kubernetes.io/*`) are
  correctly templated and that the LBC controller reconciles them into a
  functional load balancer.

**Do not use** AWS LBC scenarios if:

- You need to test TLS certificate lifecycle — use the `cert-manager` *local*
  scenarios instead. AWS LBC scenarios assume certificates are provisioned via
  AWS Certificate Manager (ACM).
- You are testing a service mesh (Istio, Linkerd) — use the `service-mesh/`
  local scenarios. Mesh scenarios on EKS add the additional dimension of
  AWS NLB interaction, which is beyond the current scope.
- You need internal-only load balancing without a public endpoint — use the
  NLB `scheme: internal` variant, but note that internal NLBs still require
  VPC-level routing.

## How

This repo does **not** run AWS LBC scenarios. They are authored as reference
implementations that you take to your own EKS cluster.

### Application pattern

Every AWS LBC scenario follows this two-phase pattern:

**Phase 1 (validation in this repo):**

1. Write the scenario YAML with `cluster.provider: eks`.
2. Validate against `engine/templates/scenario.schema.json`.
3. Run `kubectl --dry-run=client -f` against every embedded manifest snippet.
4. Run `yamllint` on the primer and all scenario YAMLs.

**Phase 2 (you, on your own EKS cluster):**

1. Authenticate to AWS: `aws configure` and
   `aws eks update-kubeconfig --region <region> --name <cluster>`.
2. Install the AWS Load Balancer Controller via Helm.
3. Apply the scenario's preinstall items and product chart.
4. Review the emitted `reports/run-*/result.yaml` and artifact bundle.

### Consumer chart wiring

The sample product chart (`examples/sample-product-chart/chart/`) exposes
value blocks for AWS LBC integration. Set these values for LBC scenarios:

```yaml
ingress:
  enabled: true
  className: alb
  annotations:
    alb.ingress.kubernetes.io/scheme: "internet-facing"
    alb.ingress.kubernetes.io/target-type: "ip"
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS": 443}]'
    alb.ingress.kubernetes.io/certificate-arn: "<REPLACE_WITH_ACM_CERT_ARN>"
    alb.ingress.kubernetes.io/healthcheck-path: "/healthz"
  hosts:
    - host: "<REPLACE_WITH_DOMAIN_NAME>"
      paths:
        - path: /
          pathType: Prefix
```

All values containing sensitive material carry `<REPLACE_WITH_...>` placeholders.
No real ACM certificate ARNs or AWS resource identifiers are stored in this
repository.

## Credential prerequisites

Before applying any AWS LBC scenario to your cluster, you must have the
following AWS credentials and IAM bindings in place.

### AWS authentication

```bash
# Configure AWS credentials (requires IAM user with EKS + IAM admin permissions)
aws configure

# Or assume a role (recommended for CI/CD)
aws sts assume-role \
  --role-arn "arn:aws:iam::<ACCOUNT_ID>:role/<ROLE_NAME>" \
  --role-session-name "chart-test-swarm-aws-lbc"

# Verify access
aws eks list-clusters --region <REGION>
```

### IRSA OIDC provider

The AWS Load Balancer Controller uses IRSA (IAM Roles for Service Accounts)
to authenticate with the AWS API. IRSA requires an OIDC identity provider
configured in IAM, associated with the EKS cluster's OIDC issuer URL.
This is a **one-time per-cluster setup**:

```bash
# Get the cluster's OIDC issuer URL
ISSUER_URL=$(aws eks describe-cluster \
  --name <CLUSTER_NAME> --region <REGION> \
  --query "cluster.identity.oidc.issuer" --output text)

# Create the OIDC provider in IAM (if it doesn't exist)
aws iam create-open-id-connect-provider \
  --url "$ISSUER_URL" \
  --client-id-list "sts.amazonaws.com" \
  --thumbprint-list "<THUMBPRINT>"

# Alternatively, use eksctl
eksctl utils associate-iam-oidc-provider \
  --region <REGION> --cluster <CLUSTER_NAME> --approve
```

### AWS Load Balancer Controller IAM permissions

The controller requires IAM permissions to manage ALBs, NLBs, WAF, Shield,
and ACM. Create the IAM policy and attach it via IRSA:

```bash
# Download the recommended IAM policy
curl -o iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

# Create the policy
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam-policy.json

# Create the IRSA service account for the controller
eksctl create iamserviceaccount \
  --cluster <CLUSTER_NAME> \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --attach-policy-arn "arn:aws:iam::<ACCOUNT_ID>:policy/AWSLoadBalancerControllerIAMPolicy" \
  --region <REGION> \
  --approve
```

Confirm the binding is active:

```bash
kubectl -n kube-system describe sa aws-load-balancer-controller
# Should show annotation: eks.amazonaws.com/role-arn: arn:aws:iam::<ACCOUNT_ID>:role/...
```

### ACM certificate

ALB Ingress scenarios with HTTPS require an ACM certificate in the same
region as the EKS cluster:

```bash
# Request a public certificate (or import an existing one)
aws acm request-certificate \
  --domain-name "<REPLACE_WITH_DOMAIN_NAME>" \
  --validation-method DNS \
  --region <REGION>

# Note the certificate ARN for the Ingress annotation
aws acm list-certificates --region <REGION>
```

## Cluster prerequisites

Every AWS LBC scenario expects the following cluster configuration.

### EKS version

**Minimum: EKS 1.28** (LBC v2.8+ requires EKS 1.22+; Gateway API support
requires EKS 1.25+).

```bash
# Create a new EKS cluster matching scenario expectations
eksctl create cluster \
  --name chart-test-swarm-eks \
  --region us-west-2 \
  --version 1.30 \
  --nodegroup-name standard-workers \
  --node-type t3.medium \
  --nodes 3 \
  --nodes-min 1 \
  --nodes-max 6 \
  --with-oidc \
  --managed
```

### Install the AWS Load Balancer Controller

The controller must be installed via Helm with the IRSA service account:

```bash
# Add the EKS Helm repo
helm repo add eks https://aws.github.io/eks-charts
helm repo update

# Install the controller
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName=<CLUSTER_NAME> \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=<REGION> \
  --set vpcId=<VPC_ID>
```

### VPC networking

All AWS LBC scenarios assume **VPC with public and private subnets**. Key
requirements:

- At least **2 public subnets** (for internet-facing ALBs and NAT gateway)
- At least **2 private subnets** (for worker nodes and internal NLBs)
- Subnet auto-discovery tags for the LBC:
  - Public subnets: `kubernetes.io/role/elb: 1`
  - Private subnets: `kubernetes.io/role/internal-elb: 1`
- Cluster security group must allow inbound from ALB/NLB security groups

Verify your VPC tagging:

```bash
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$(aws eks describe-cluster --name <CLUSTER_NAME> --query 'cluster.resourcesVpcConfig.vpcId' --output text)" \
  --query "Subnets[].{ID:SubnetId, AZ:AvailabilityZone, Tags:Tags}" \
  --output table
```

### Required add-ons

| Component | Required for | Installation |
|---|---|---|
| AWS Load Balancer Controller v2.8+ | All LBC scenarios | `helm install aws-load-balancer-controller eks/aws-load-balancer-controller` |
| OIDC provider + IRSA | All LBC scenarios | `eksctl utils associate-iam-oidc-provider` |
| VPC CNI | IP target mode | Included by default on EKS |
| CoreDNS + kube-proxy | All scenarios | Included in EKS managed add-ons |
| Gateway API CRDs | Gateway API variants | `kubectl apply -k github.com/kubernetes-sigs/gateway-api?ref=v1.1.0` |

## Variants

Three scenario variants are authored under
`examples/sample-product-chart/chart-test/scenarios/`. All use
`cluster.provider: eks`, carry `category: networking`, `integration:
aws-load-balancer-controller`, and the `AUTHORED ONLY` banner.

| Variant | File | What it exercises |
|---|---|---|
| alb-ingress | `networking-aws-lbc-alb-ingress.yaml` | Ingress → ALB provisioning; TLS via ACM; health checks |
| nlb-service | `networking-aws-lbc-nlb-service.yaml` | Service type LoadBalancer → NLB; cross-zone load balancing |
| gateway-api | `networking-aws-lbc-gateway-api.yaml` | Gateway + HTTPRoute → ALB via Gateway API |

### alb-ingress

This variant verifies that the AWS Load Balancer Controller provisions an
Application Load Balancer from a Kubernetes Ingress resource.

**Product chart values:**

```yaml
ingress:
  enabled: true
  className: alb
  annotations:
    alb.ingress.kubernetes.io/scheme: "internet-facing"
    alb.ingress.kubernetes.io/target-type: "ip"
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS": 443}]'
    alb.ingress.kubernetes.io/certificate-arn: "<REPLACE_WITH_ACM_CERT_ARN>"
```

**Smoke-script behavior:** Retrieves the ALB DNS name from the Ingress status
(`kubectl get ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'`),
then performs an HTTPS GET. Expects HTTP 200.

### nlb-service

This variant verifies that the AWS Load Balancer Controller provisions a
Network Load Balancer from a Service of type LoadBalancer.

**Product chart values:**

```yaml
service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "external"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
    service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"
```

**Smoke-script behavior:** Retrieves the NLB DNS name from the Service status,
then performs an HTTP GET. Expects HTTP 200.

### gateway-api

This variant verifies that the AWS Load Balancer Controller provisions an
ALB from a Gateway API `Gateway` + `HTTPRoute` pair (requires LBC v2.8+ and
Gateway API CRDs).

**Product chart values:**

```yaml
gatewayRoute:
  enabled: true
  parentGateway:
    name: chart-test-swarm-aws-gateway
    namespace: "<REPLACE_WITH_NAMESPACE>"
```

**Smoke-script behavior:** Waits for the Gateway to have an assigned IP/hostname,
then performs an HTTP GET. Expects HTTP 200.

## Assertions

| Type | What it verifies |
|---|---|
| `helm-status-deployed` | Product chart installed successfully |
| `pods-ready` | All product pods Ready |
| `smoke-script` | Per-variant behavior (see variant descriptions) |
| `service-reachable` | ALB/NLB DNS resolves and returns HTTP 200 |

**Important:** These assertions are NOT run from this repository. They are
authored for reference and validated structurally (dry-run, yamllint) but never
executed in CI or local test runs.

## Known gotchas

- **Subnet tagging is required**: The LBC discovers subnets via tags
  (`kubernetes.io/role/elb` and `kubernetes.io/role/internal-elb`). If subnets
  are not tagged, ALB provisioning will fail with "no subnets found."

- **IP target mode requires VPC CNI**: When
  `alb.ingress.kubernetes.io/target-type: ip` is set (the default for EKS),
  the ALB sends traffic directly to Pod IPs. This requires VPC CNI and
  security groups allowing traffic from the ALB to Pod IPs.

- **ALB provisioning latency**: An ALB takes 2-5 minutes to become active.
  Smoke-scripts poll the Ingress status with a timeout of 10 minutes.

- **ACM certificate must be in the same region**: The ACM certificate ARN
  referenced in the Ingress annotation must be in the same AWS region as the
  EKS cluster. Cross-region ACM certificates are not supported.

- **IRSA credential propagation requires Pod restart**: After creating or
  modifying the IRSA service account, existing controller pods must be
  restarted for the new IAM role to take effect.

- **NLB cross-zone load balancing is not enabled by default**: For NLB
  Service scenarios, add the annotation
  `service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"`
  to enable cross-zone traffic distribution.

- **Gateway API requires CRD installation**: Before using the Gateway API
  variant, install the Gateway API CRDs:
  `kubectl apply -k github.com/kubernetes-sigs/gateway-api?ref=v1.1.0`

## References

- [AWS Load Balancer Controller documentation](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)
- [ALB Ingress annotations](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/ingress/annotations/)
- [NLB Service annotations](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/service/annotations/)
- [Gateway API support](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/gateway/api/)
- [IAM policy for the controller](https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json)
- [EKS best practices — Load Balancing](https://aws.github.io/aws-eks-best-practices/networking/load-balancing/)
