# terraform-eks-karpenter
 # Getting Started with Terraform
   
   #Set up Karpenter with a Terraform cluster
   Karpenter automatically provisions new nodes in response to unschedulable pods. Karpenter does this by observing events within the Kubernetes cluster, and then sending commands to the underlying cloud provider.
   
   
  #Required Utilities 
   1) AWS CLI
   2) kubectl - the Kubernetes CLI
   3) terraform - infrastructure-as-code tool made by HashiCorp
   4) Configure the AWS CLI with a user that has sufficient privileges to create an EKS cluster. Verify that the CLI can authenticate properly by running aws sts get-caller- identity
  #Setting up Variables 
  export AWS_DEFAULT_REGION="us-east-1"
