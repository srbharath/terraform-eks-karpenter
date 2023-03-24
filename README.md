 # Getting Started with Terraform
   
   #Set up Karpenter with a Terraform cluster
   Karpenter automatically provisions new nodes in response to unschedulable pods. Karpenter does this by observing events within the Kubernetes cluster, and then sending commands to the underlying cloud provider.
   
   
  # Required Utilities 
   1) AWS CLI
   2) kubectl - the Kubernetes CLI
   3) terraform - infrastructure-as-code tool made by HashiCorp
   4) Configure the AWS CLI with a user that has sufficient privileges to create an EKS cluster. Verify that the CLI can authenticate properly by running aws sts get-caller- identity


# Setting up Variables 
  export AWS_DEFAULT_REGION="us-east-1"
 
 # The first thing we need to do is create our main.tf file and place the following in it.
 terraform {
  required_version = "~> 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.5"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

locals {
  cluster_name = "karpenter-demo"
 #Used to determine correct partition (i.e. - `aws`, `aws-gov`, `aws-cn`, etc.)
  partition = data.aws_partition.current.partition

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)
}

data "aws_partition" "current" {}
data "aws_availability_zones" "available" {}
data "aws_ecrpublic_authorization_token" "token" {}


# Create a Cluster
We’re going to use three different Terraform modules to create our cluster

1) eks which creates the EKS cluster and associated cluster resources
2) karpenter which creates Karpenter IAM role(s), instance profile, SQS queue, and EvnetBridge rules
3) vpc which creates a VPC suitable for provisioning our cluster
Add the following to your main.tf to create the VPC and EKS cluster.


module "vpc" {
  #https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/latest
  source  = "terraform-aws-modules/vpc/aws"
  version = "3.18.1"

  name = local.cluster_name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    # Tags subnets for Karpenter auto-discovery
    "karpenter.sh/discovery" = "true"
  }
}

module "eks" {
  #https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest
  source  = "terraform-aws-modules/eks/aws"
  version = "18.31.0"

  cluster_name    = local.cluster_name
  cluster_version = "1.24"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  #Required for Karpenter role below
  enable_irsa = true

  node_security_group_additional_rules = {
    ingress_nodes_karpenter_port = {
      description                   = "Cluster API to Node group for Karpenter webhook"
      protocol                      = "tcp"
      from_port                     = 8443
      to_port                       = 8443
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

  node_security_group_tags = {
    #.NOTE - if creating multiple security groups with this module, only tag the
    #security group that Karpenter should utilize with the following tag
    #(i.e. - at most, only one security group should have this tag in your account)
    "karpenter.sh/discovery" = local.cluster_name
  }

   #Only need one node to get Karpenter up and running.
   #This ensures core services such as VPC CNI, CoreDNS, etc. are up and running
   #so that Karpenter can be deployed and start managing compute capacity as required
  eks_managed_node_groups = {
    initial = {
      instance_types = ["m5.large"]
      #Not required nor used - avoid tagging two security groups with same tag as well
      create_security_group = false

      #Ensure enough capacity to run 2 Karpenter pods
      min_size     = 2
      max_size     = 3
      desired_size = 2
    }
  }
}

# Create the EC2 Spot Service Linked Role
This step is only necessary if this is the first time you’re using EC2 Spot in this account.

aws iam create-service-linked-role --aws-service-name spot.amazonaws.com
#If the role has already been successfully created, you will see:
#An error occurred (InvalidInput) when calling the CreateServiceLinkedRole operation: Service role name AWSServiceRoleForEC2Spot has been taken in this account, please try a different suffix.

# Create the Karpenter AWS Resources 

Add the following to your main.tf to create:

* AWS IAM instance profile Karpenter will assign to nodes created
* AWS IAM role for service accounts (IRSA) used by the Karpenter controller
* AWS SQS queue and EventBridge rules for node termination handling


module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "18.31.0"

  cluster_name = module.eks.cluster_name

  irsa_oidc_provider_arn          = module.eks.oidc_provider_arn
  irsa_namespace_service_accounts = ["karpenter:karpenter"]

  # Since Karpenter is running on an EKS Managed Node group,
  # we can re-use the role that was created for the node group
  create_iam_role = false
  iam_role_arn    = module.eks.eks_managed_node_groups["initial"].iam_role_arn
}


# Install Karpenter Helm Chart

We are going to use the helm_release Terraform resource to do the deploy and pass in the cluster details and IAM role Karpenter needs to assume.

Add the following to your main.tf to provision Karpenter via its Helm chart.


provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

resource "helm_release" "karpenter" {
  namespace        = "karpenter"
  create_namespace = true

  name                = "karpenter"
  repository          = "oci://public.ecr.aws/karpenter"
  repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password = data.aws_ecrpublic_authorization_token.token.password
  chart               = "karpenter"
  version             = "v0.21.1"

  set {
    name  = "settings.aws.clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "settings.aws.clusterEndpoint"
    value = module.eks.cluster_endpoint
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.karpenter.irsa_arn
  }

  set {
    name  = "settings.aws.defaultInstanceProfile"
    value = module.karpenter.instance_profile_name
  }

  set {
    name  = "settings.aws.interruptionQueueName"
    value = module.karpenter.queue_name
  }
}

# Provisioner

A single Karpenter provisioner is capable of handling many different pod shapes. Karpenter makes scheduling and provisioning decisions based on pod attributes such as labels and affinity. In other words, Karpenter eliminates the need to manage many different node groups.

Create a default provisioner using the command below. This provisioner configures instances to connect to your cluster’s endpoint and discovers resources like subnets and security groups using the cluster’s name.

The ttlSecondsAfterEmpty value configures Karpenter to terminate empty nodes. This behavior can be disabled by leaving the value undefined.

# Add the following to your main.tf to deploy the Karpenter provisioner.


provider "kubectl" {
  apply_retry_count      = 5
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

resource "kubectl_manifest" "karpenter_provisioner" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1alpha5
    kind: Provisioner
    metadata:
      name: default
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]
      limits:
        resources:
          cpu: 1000
      providerRef:
        name: default
      ttlSecondsAfterEmpty: 30
  YAML

  depends_on = [
    helm_release.karpenter
  ]
}

resource "kubectl_manifest" "karpenter_node_template" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1alpha1
    kind: AWSNodeTemplate
    metadata:
      name: default
    spec:
      subnetSelector:
        karpenter.sh/discovery: "true"
      securityGroupSelector:
        karpenter.sh/discovery: ${module.eks.cluster_name}
      tags:
        karpenter.sh/discovery: ${module.eks.cluster_name}
  YAML

  depends_on = [
    helm_release.karpenter
  ]
}

# After that run the following commnads

terraform init

terraform apply --auto-approve

# First Use

Karpenter is now active and ready to begin provisioning nodes. Create some pods using a deployment, and watch Karpenter provision nodes in response.

Before we can start interacting with the cluster, we need to update our local kubeconfig:

aws eks update-kubeconfig --name karpenter-demo

======================================================================================================================================================================

# Automatic Node Provisioning

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inflate
spec:
  replicas: 0
  selector:
    matchLabels:
      app: inflate
  template:
    metadata:
      labels:
        app: inflate
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: inflate
          image: public.ecr.aws/eks-distro/kubernetes/pause:3.7
          resources:
            requests:
              cpu: 1
EOF
kubectl scale deployment inflate --replicas 5
kubectl logs -f -n karpenter -l app.kubernetes.io/name=karpenter -c controller

# Automatic Node Termination

kubectl delete deployment inflate
kubectl logs -f -n karpenter -l app.kubernetes.io/name=karpenter -c controller

# Cleanup 

To avoid additional charges, remove the demo infrastructure from your AWS account. Since Karpenter is managing nodes outside of Terraform’s view, we need to remove the pods and node first (if you haven’t already). Once the node is removed, you can remove the rest of the infrastructure and clean up Karpenter created LaunchTemplates.

kubectl delete deployment inflate
kubectl delete node -l karpenter.sh/provisioner-name=default
terraform destroy


