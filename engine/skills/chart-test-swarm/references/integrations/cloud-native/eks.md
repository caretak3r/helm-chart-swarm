# eks

**AUTHORED ONLY — not run from this repo.** The scenarios referenced here are
authored and validated via `kubectl --dry-run=client` and `kubeval` against a
local kind cluster. No `kubectl apply`, `helm install`, or `aws` invocation
targets a real EKS cluster from this repository. Apply them yourself to your
own EKS cluster.

## What

Amazon Elastic Kubernetes Service (EKS) is AWS's managed Kubernetes service.
EKS provides a control plane operated by AWS, integrated with IAM, VPC
networking, CloudWatch logging, and the broader AWS service ecosystem. For
chart-test-swarm, the EKS primer documents the AWS-specific integrations that
a Helm chart may depend on when deployed to EKS — in particular how the chart
can authenticate to AWS services, provision cloud load balancers, manage AWS
resources declaratively from within the cluster, and run serverless Pods.

The four AWS features covered by this primer are:

- **IRSA (IAM Roles for Service Accounts)** — maps a Kubernetes ServiceAccount
  to an AWS IAM role via OIDC federation so pods can call AWS APIs (S3, DynamoDB,
  SQS, Secrets Manager) without embedding long-lived IAM access keys.
- **AWS Load Balancer Controller (ALB Ingress Controller)** — provisions AWS
  Application Load Balancers (ALB) and Network Load Balancers (NLB) from
  Kubernetes Ingress and Service resources, including advanced routing rules,
  TLS termination at the load balancer, and WAF integration.
- **ACK (AWS Controllers for Kubernetes)** — manages AWS services (RDS, S3,
  DynamoDB, ElastiCache, SNS, SQS, and more) directly from Kubernetes using
  custom resources (CRDs). Operators define a `Table` or `Bucket` CR and ACK
  reconciles it into a real AWS resource.
- **Fargate** — serverless compute engine for EKS that runs Pods without
  provisioning or managing EC2 worker nodes. Each Pod gets its own isolated
  VM; no node-level sharing, no `DaemonSet` compatibility limitations.

These features are EKS-specific. They cannot be exercised on kind or minikube
because they depend on AWS infrastructure (IAM, VPC, ALB, Fargate). The
scenarios authored for this integration are **design-only** — they serve as
reference implementations that a user ships to their own EKS cluster.

## Target Kubernetes version

EKS 1.30+ (EKS extended support window: Standard support through July 2025;
platform version `eks.7` or later).

- IRSA OIDC provider is available on all EKS versions. The cluster's OIDC
  issuer URL is published in the cluster description and is immutable after
  cluster creation.
- AWS Load Balancer Controller v2.8+ requires EKS 1.25+ and supports Ingress
  (`networking.k8s.io/v1`) and Gateway API (`gateway.networking.k8s.io/v1`).
- ACK service controllers support EKS 1.23+ and Kubernetes CRD `apiextensions.k8s.io/v1`.
- Fargate is available on all EKS platform versions. The Fargate profile
  selector model uses namespace + label matching.

All scenario YAMLs authored under `cloud-native/` carry an annotation
`chart-test-swarm/target-k8s-version: eks-1.30` to pin the expected Kubernetes
API version.

## When

Use EKS cloud-native scenarios when the Helm chart under test:

- Depends on AWS IAM for service-to-service authentication (e.g. accessing
  S3 buckets, DynamoDB tables, SQS queues, or Secrets Manager secrets). IRSA
  is the preferred path — no IAM access keys in Kubernetes Secrets.
- Must be exposed through an AWS Application Load Balancer (ALB) with
  host-based routing, path-based routing, TLS termination via AWS Certificate
  Manager (ACM), or WAF integration. The AWS Load Balancer Controller maps
  Ingress resources to ALB configurations.
- Manages AWS resources as part of the application lifecycle — e.g. an
  application that provisions its own S3 bucket, RDS instance, or DynamoDB
  table via ACK custom resources declared in the Helm chart templates.
- Runs on EKS Fargate and must verify that Pods are scheduled onto Fargate
  capacity, that the Fargate profile selector matches, and that `hostNetwork`
  and `DaemonSet` guardrails are respected.
- Must prove that the chart's IRSA annotations (`eks.amazonaws.com/role-arn`)
  are correctly templated and that the projected service account token
  successfully exchanges for an AWS credential.

**Do not use** EKS scenarios if:

- You need to test TLS certificate lifecycle — use the `cert-manager` *local*
  scenarios instead. EKS scenarios assume cert-manager is already provisioned
  or that certificates are provisioned via AWS Certificate Manager (ACM).
- You are testing a service mesh (Istio, Linkerd) — use the `service-mesh/`
  local scenarios. Mesh scenarios on EKS add the additional dimension of
  AWS NLB interaction, which is beyond the current scenario scope.
- You are testing policy enforcement (Gatekeeper, Kyverno) — use the `policy/`
  local scenarios. Amazon EKS Pod Identity and EKS Security Groups for Pods
  are not in scope for these primers.

## How

This repo does **not** run EKS scenarios. They are authored as reference
implementations that you take to your own EKS cluster.

### Application pattern

Every EKS cloud-native scenario follows this two-phase pattern:

**Phase 1 (validation in this repo):**

1. Write the scenario YAML with `cluster.provider: eks`.
2. Validate against `engine/templates/scenario.schema.json`.
3. Run `kubectl --dry-run=client -f` against every embedded manifest snippet.
4. Run `kubeval --strict --kubernetes-version 1.30.0` against every
   `raw_manifest` preinstall path.
5. Run `helm lint` on the product chart and `helm template` on any
   helm-values snippet.
6. Run `yamllint` on the primer and all scenario YAMLs.

**Phase 2 (you, on your own EKS cluster):**

1. Authenticate to AWS: `aws configure` and
   `aws eks update-kubeconfig --region <region> --name <cluster>`.
2. Set up IAM prerequisites (OIDC provider, IAM role with trust policy,
   IRSA trust relationship).
3. Run `bash engine/scripts/run-scenario.sh <scenario.yaml>` with the
   environment variable `CLUSTER_NAME=chart-test-swarm-eks-<id>` and
   `PROVIDER=eks`.
4. Review the emitted `reports/run-*/result.yaml` and artifact bundle.

### Consumer chart wiring

The sample product chart (`examples/sample-product-chart/chart/`) exposes value
blocks for EKS-specific features. Set these values for EKS scenarios:

```yaml
# IRSA — annotate the ServiceAccount with an IAM role ARN
eks:
  irsa:
    enabled: true
    roleArn: "<REPLACE_WITH_IAM_ROLE_ARN>"

  # AWS Load Balancer Controller — provision an ALB via Ingress
  loadBalancerController:
    enabled: true
    certificateArn: "<REPLACE_WITH_ACM_CERT_ARN>"
    scheme: "internet-facing"  # or "internal"

  # ACK — declare AWS resources via custom resources
  ack:
    enabled: true
    # Service controllers installed separately via helm
    rdsInstanceIdentifier: "<REPLACE_WITH_DB_IDENTIFIER>"

  # Fargate — schedule pods onto Fargate
  fargate:
    enabled: true
    fargateProfileName: "<REPLACE_WITH_FARGATE_PROFILE_NAME>"
```

All values containing sensitive material carry `<REPLACE_WITH_...>` placeholders.
No real IAM role ARNs, ACM certificate ARNs, or AWS resource identifiers are
stored in this repository.

## Credential prerequisites

Before applying any EKS scenario to your cluster, you must have the following
AWS credentials and IAM bindings in place.

### AWS authentication

```bash
# Configure AWS credentials (requires IAM user with EKS + IAM admin permissions)
aws configure

# Or assume a role (recommended for CI/CD)
aws sts assume-role \
  --role-arn "arn:aws:iam::<ACCOUNT_ID>:role/<ROLE_NAME>" \
  --role-session-name "chart-test-swarm-eks"

# Verify access
aws eks list-clusters --region <REGION>
```

### IRSA OIDC provider

IRSA requires an OIDC identity provider configured in IAM, associated with
the EKS cluster's OIDC issuer URL. This is a **one-time per-cluster setup**:

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

### IRSA IAM role with trust policy

Each Kubernetes ServiceAccount that uses IRSA needs an IAM role whose trust
policy allows the EKS cluster's OIDC provider to assume it:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/oidc.eks.<REGION>.amazonaws.com/id/<OIDC_ID>"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.<REGION>.amazonaws.com/id/<OIDC_ID>:sub": "system:serviceaccount:<NAMESPACE>:<SERVICE_ACCOUNT_NAME>",
          "oidc.eks.<REGION>.amazonaws.com/id/<OIDC_ID>:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
```

Create the role and attach the trust policy:

```bash
# Create the IAM role with the OIDC trust relationship
eksctl create iamserviceaccount \
  --name <SERVICE_ACCOUNT_NAME> \
  --namespace <NAMESPACE> \
  --cluster <CLUSTER_NAME> \
  --region <REGION> \
  --role-name "chart-test-swarm-eks-irsa-role" \
  --attach-policy-arn "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess" \
  --approve
```

Confirm the binding is active:

```bash
aws iam get-role --role-name chart-test-swarm-eks-irsa-role
kubectl -n <NAMESPACE> describe sa <SERVICE_ACCOUNT_NAME>
# Should show annotation: eks.amazonaws.com/role-arn: arn:aws:iam::<ACCOUNT_ID>:role/chart-test-swarm-eks-irsa-role
```

### AWS Load Balancer Controller IAM permissions

The AWS Load Balancer Controller requires IAM permissions to manage ALBs,
NLBs, WAF, Shield, and ACM. Create the IAM policy and attach it:

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

### ACK IAM permissions

Each ACK service controller requires an IRSA role with permissions scoped to
the specific AWS service it manages. For example, the S3 controller:

```bash
eksctl create iamserviceaccount \
  --name ack-s3-controller \
  --namespace ack-system \
  --cluster <CLUSTER_NAME> \
  --region <REGION> \
  --role-name "chart-test-swarm-eks-ack-s3-role" \
  --attach-policy-arn "arn:aws:iam::aws:policy/AmazonS3FullAccess" \
  --approve
```

Repeat for each service controller your scenarios use (RDS, DynamoDB, SQS, etc.).

## Cluster prerequisites

Every EKS scenario in this primer expects the following cluster configuration.

### EKS version

**Minimum: EKS 1.30** (platform version `eks.7` or later).

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

### Required add-ons and controllers

| Component | Required for | Installation |
|---|---|---|
| OIDC provider | IRSA scenarios | `eksctl utils associate-iam-oidc-provider` |
| AWS Load Balancer Controller v2.8+ | ALB Ingress scenarios | `helm install aws-load-balancer-controller eks/aws-load-balancer-controller` |
| ACK service controllers | ACK scenarios (RDS, S3, DynamoDB) | `helm install ack-<service>-controller oci://public.ecr.aws/aws-controllers-k8s/<service>-chart` |
| Fargate profile | Fargate scenarios | `eksctl create fargateprofile` |
| CoreDNS + kube-proxy | All scenarios | Included in EKS managed add-ons |
| VPC CNI | All scenarios | Included by default |
| AWS EBS CSI Driver | Optional: PVC scenarios | `eksctl create addon --name aws-ebs-csi-driver --cluster <CLUSTER_NAME>` |

### VPC networking

All EKS scenarios assume **VPC with public and private subnets**. EKS creates
a dedicated VPC by default when using `eksctl create cluster`. Key requirements:

- At least **2 public subnets** (for internet-facing ALBs and NAT gateway)
- At least **2 private subnets** (for worker nodes and internal NLBs)
- Subnet auto-discovery tags for the AWS Load Balancer Controller:
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

### Fargate profile

Fargate scenarios require a Fargate profile that matches the product chart's
namespace and Pod labels:

```bash
eksctl create fargateprofile \
  --cluster <CLUSTER_NAME> \
  --name chart-test-swarm-fargate \
  --namespace <NAMESPACE> \
  --labels app.kubernetes.io/name=skywatcher
```

Fargate profiles are **immutable** after creation. If you need to change the
selector, delete and recreate the profile.

### Network mode for EKS

EKS scenarios expect:

- **3 nodes minimum** for non-Fargate scenarios (one per AZ for HA)
- **IRSA enabled** — the cluster must have an associated OIDC provider
- **VPC CNI** — enables Pod-to-Pod networking across subnets; required for
  ALB target group registration which uses Pod IPs directly
- **No `hostNetwork: true`** on Fargate scenarios — Fargate Pods cannot use
  `hostNetwork` and will fail to schedule

## Variants

Four scenario variants are authored under
`examples/sample-product-chart/chart-test/scenarios/`. All use
`cluster.provider: eks` and carry the `AUTHORED ONLY` banner.

| Variant | File | AWS feature | What it exercises |
|---|---|---|---|
| irsa | `cloud-native-eks-irsa.yaml` | IRSA | SA annotated with `eks.amazonaws.com/role-arn`; pod mounts projected token; smoke-script calls AWS S3 API |
| alb-ingress | `cloud-native-eks-alb-ingress.yaml` | ALB Ingress Controller | Ingress → ALB provisioning; TLS via ACM; smoke-script curls ALB DNS |
| ack-s3 | `cloud-native-eks-ack-s3.yaml` | ACK (S3) | `Bucket` CR → S3 bucket creation; smoke-script puts/gets object |
| fargate | `cloud-native-eks-fargate.yaml` | Fargate | Fargate profile selector; pod schedules without nodes; smoke-script verifies Fargate runtime |

Each variant file carries the `AUTHORED ONLY` notice as a YAML comment at the
top of the file. The full scenario paths are:

- `examples/sample-product-chart/chart-test/scenarios/cloud-native-eks-irsa.yaml`
- `examples/sample-product-chart/chart-test/scenarios/cloud-native-eks-alb-ingress.yaml`
- `examples/sample-product-chart/chart-test/scenarios/cloud-native-eks-ack-s3.yaml`
- `examples/sample-product-chart/chart-test/scenarios/cloud-native-eks-fargate.yaml`

### irsa

This variant verifies that a Kubernetes ServiceAccount annotated with
`eks.amazonaws.com/role-arn` successfully obtains AWS credentials from the
STS web identity endpoint and uses them to call the S3 API.

**Key preinstall items:**

```yaml
# ServiceAccount with IRSA annotation
kind: raw_manifest
path: chart-test/fixtures/cloud-native/eks/irsa-serviceaccount.yaml
```

The fixture contains:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: chart-test-swarm-eks-sa
  namespace: <REPLACE_WITH_NAMESPACE>
  annotations:
    eks.amazonaws.com/role-arn: "<REPLACE_WITH_IAM_ROLE_ARN>"
```

**Smoke-script behavior:** The assertion uses the AWS SDK (or `aws-cli` via
`curl` to the EKS Pod Identity webhook) to call `s3:ListBuckets`. Verifies
the response is an HTTP 200 with a valid bucket listing. Does NOT embed
long-lived AWS access keys — relies entirely on the IRSA-provisioned
credentials from the projected service account token.

### alb-ingress

This variant verifies that the AWS Load Balancer Controller provisions an
Application Load Balancer from a Kubernetes Ingress resource.

**Key preinstall items:**

```yaml
# AWS Load Balancer Controller — installed via helm in cluster.preinstall
kind: helm
repo:
  name: eks
  url: https://aws.github.io/eks-charts
chart: aws-load-balancer-controller
version: "1.8.0"
release: aws-load-balancer-controller
namespace: kube-system
values:
  clusterName: <REPLACE_WITH_CLUSTER_NAME>
  serviceAccount:
    create: true
    name: aws-load-balancer-controller
    annotations:
      eks.amazonaws.com/role-arn: "<REPLACE_WITH_LBC_ROLE_ARN>"
```

**Product chart ingress configuration:**

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

**Smoke-script behavior:** Retrieves the ALB DNS name from the Ingress status
(`kubectl get ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'`),
then performs an HTTPS GET against `https://<ALB_DNS>/`. Expects HTTP 200
and the product chart's known response body. The TLS certificate is validated
against the standard CA bundle (ACM certificates are trusted by default).

### ack-s3

This variant verifies that an ACK `Bucket` custom resource is reconciled by
the ACK S3 controller into a real S3 bucket, and that the product chart can
read from and write to it.

**Key preinstall items:**

```yaml
# ACK S3 controller — installed via helm
kind: helm
repo:
  name: ack
  url: https://aws-controllers-k8s.github.io/community
chart: oci://public.ecr.aws/aws-controllers-k8s/s3-chart
version: "1.0.0"
release: ack-s3-controller
namespace: ack-system
values:
  aws:
    region: <REPLACE_WITH_AWS_REGION>
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: "<REPLACE_WITH_ACK_S3_ROLE_ARN>"
---
# S3 Bucket custom resource
kind: raw_manifest
path: chart-test/fixtures/cloud-native/eks/ack-s3-bucket.yaml
```

The fixture contains:

```yaml
apiVersion: s3.services.k8s.aws/v1alpha1
kind: Bucket
metadata:
  name: chart-test-swarm-eks-ack-bucket
  namespace: <REPLACE_WITH_NAMESPACE>
spec:
  name: chart-test-swarm-eks-ack-<REPLACE_WITH_SUFFIX>
```

**Smoke-script behavior:** Waits for the `Bucket` resource to reach `ACK.ResourceSynced=True`,
then uses the AWS SDK (credentialed via IRSA) to PUT a test object and GET it
back, verifying byte equality. Cleans up the test object after verification.

### fargate

This variant verifies that Pods are scheduled onto AWS Fargate capacity when
the namespace matches a Fargate profile selector.

**No additional preinstall items are required** beyond the standard EKS
cluster configuration described in the Cluster prerequisites section. The
product chart's namespace must be covered by a Fargate profile.

**Product chart values for Fargate:**

```yaml
eks:
  fargate:
    enabled: true

# Fargate pods cannot use hostNetwork or hostPort
podSecurityContext:
  fsGroup: 65534

# Fargate requires at least 0.25 vCPU and 0.5 GiB memory
resources:
  requests:
    cpu: "256m"
    memory: "512Mi"
  limits:
    cpu: "512m"
    memory: "1Gi"
```

**Smoke-script behavior:**

1. Verifies that the Pod's node name contains `fargate-` (the Fargate node
   naming convention).
2. Checks that `kubectl describe pod` shows `NomadNodeSelector` or
   `Fargate` in the annotations.
3. Confirms the Pod is `Running` and serves HTTP 200.
4. Asserts that no `DaemonSet` pods are scheduled onto the Fargate
   namespace (Fargate does not support `DaemonSet`).

### Assertions

| Type | What it verifies |
|---|---|
| `helm-status-deployed` | Product chart installed successfully |
| `pods-ready` | All product pods Ready (Fargate: verify Fargate node name) |
| `smoke-script` | Per-variant behavior (see variant descriptions) |
| `service-reachable` | ALB DNS resolves and returns HTTP 200 (alb-ingress variant) |

Assertion scripts live under
`examples/sample-product-chart/chart-test/assertions/cloud-native/eks/` and are
referenced by relative path from the scenario YAML. Each smoke-script receives
`RELEASE`, `NAMESPACE`, `KUBECONFIG`, `KUBE_CONTEXT`, `PROJECT_DIR`, and
`AWS_REGION` via the environment.

**Important:** These assertions are NOT run from this repository. The
smoke-scripts contain calls to `aws s3`, `aws sts`, and other AWS CLI
operations that require real AWS credentials and live EKS clusters. They are
authored for reference and validated structurally (dry-run, kubeval, yamllint)
but never executed in CI or local test runs.

## Known gotchas

- **IRSA credential propagation requires Pod restart**: After adding the
  `eks.amazonaws.com/role-arn` annotation to a ServiceAccount, existing Pods
  do not automatically receive the new IAM role. Pods must be recreated
  (e.g. `kubectl rollout restart deployment/<name>`) for the EKS Pod Identity
  webhook to inject the `AWS_WEB_IDENTITY_TOKEN_FILE` and
  `AWS_ROLE_ARN` environment variables.

- **IRSA token expiry and rotation**: The projected service account token
  used by IRSA is valid for 12 hours by default. The AWS SDK automatically
  refreshes credentials from STS, but long-running Pods must use an AWS SDK
  version that supports credential refreshing. Python `boto3` >= 1.9 and
  Go `aws-sdk-go-v2` >= 1.0 handle this transparently.

- **ALB Ingress Controller requires subnet tagging**: The controller discovers
  subnets via tags (`kubernetes.io/role/elb` and
  `kubernetes.io/role/internal-elb`). If subnets are not tagged, ALB
  provisioning will fail with "no subnets found." Verify with:

  ```bash
  kubectl logs -n kube-system deployment/aws-load-balancer-controller | grep "subnet"
  ```

- **ALB target group uses IP targets, not instance targets**: When
  `alb.ingress.kubernetes.io/target-type: ip` is set (the default for EKS),
  the ALB sends traffic directly to Pod IPs. This requires the VPC CNI to
  be functioning and the security group to allow traffic from the ALB to
  Pod IPs on the target port.

- **ALB provisioning latency**: An ALB provisioned from an Ingress takes
  2–5 minutes to become active. The smoke-script polls the Ingress
  `status.loadBalancer.ingress` field with a timeout of 10 minutes.

- **ACK controller requires exactly one controller per service per cluster**:
  Installing multiple instances of the same ACK service controller (e.g. two
  S3 controllers) will cause conflicting reconciliation loops. Each service
  controller manages resources cluster-wide; namespace-scoped isolation is
  not yet supported.

- **ACK resource deletion cascades**: When the `Bucket` or `Table` CR is
  deleted, ACK deletes the underlying AWS resource. This behavior is
  controlled by the `spec.deletionPolicy` field. Set to `retain` if you
  want to keep the AWS resource after the CR is removed. The default is
  `delete`.

- **Fargate prohibits `hostNetwork` and `hostPort`**: Pods that use
  `hostNetwork: true` or `hostPort` will be rejected by the Fargate
  admission controller. The scenario YAML for the Fargate variant explicitly
  avoids these settings.

- **Fargate DaemonSet incompatibility**: Fargate does not support `DaemonSet`
  resources because there is no node to daemonize on — each Fargate Pod
  runs in its own isolated VM. Charts that deploy `DaemonSet` resources
  (e.g. monitoring agents, log shippers) must provide a Fargate-compatible
  alternative (e.g. sidecar container, `fluent-bit` as a sidecar).

- **Fargate node labeling**: Fargate Pods run on virtual nodes with names
  like `fargate-ip-192-168-0-1.us-west-2.compute.internal`. Do not rely on
  EC2 node metadata (instance type, AMI ID) — these are not applicable to
  Fargate Pods. Use the `eks.amazonaws.com/compute-type: fargate` label
  for Fargate-specific node affinity.

- **Fargate Pod storage**: Fargate Pods receive 20 GiB of ephemeral storage
  by default. This storage is tied to the Pod lifecycle and is deleted when
  the Pod terminates. For persistent storage, use EFS (via the EFS CSI
  driver) which is compatible with Fargate. EBS volumes are NOT supported
  on Fargate.

- **IRSA and Fargate compatibility**: IRSA works on Fargate Pods exactly as
  on EC2 Pods — the same `eks.amazonaws.com/role-arn` annotation and
  projected service account token mechanism applies. No additional
  configuration is needed.

- **ACK controllers on Fargate**: ACK controllers themselves can run on
  Fargate, but service controllers that manage resources requiring EC2
  integration (e.g. the EC2 controller) may need to run on EC2 nodes.
  Controllers for API-only services (S3, DynamoDB, SQS, SNS) work
  correctly on Fargate.

## References

- [EKS documentation](https://docs.aws.amazon.com/eks/latest/userguide/)
- [IAM Roles for Service Accounts (IRSA)](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
- [Creating an OIDC provider for EKS](https://docs.aws.amazon.com/eks/latest/userguide/enable-iam-roles-for-service-accounts.html)
- [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)
- [ALB Ingress annotations](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/ingress/annotations/)
- [AWS Controllers for Kubernetes (ACK)](https://aws-controllers-k8s.github.io/community/)
- [ACK installation guide](https://aws-controllers-k8s.github.io/community/docs/user-docs/install/)
- [EKS Fargate](https://docs.aws.amazon.com/eks/latest/userguide/fargate.html)
- [Fargate profile creation](https://docs.aws.amazon.com/eks/latest/userguide/fargate-profile.html)
- [eksctl — official EKS CLI](https://eksctl.io/)
- [EKS best practices guide](https://aws.github.io/aws-eks-best-practices/)
- [EKS IAM roles reference](https://docs.aws.amazon.com/eks/latest/userguide/security-iam-reference.html)
- [Amazon ECR Public Gallery — ACK charts](https://gallery.ecr.aws/aws-controllers-k8s/)
