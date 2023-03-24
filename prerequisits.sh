#for amazon linux
yum install aws-cli -y
sudo curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo curl -LO https://dl.k8s.io/release/v1.26.0/bin/linux/amd64/kubectl
sudo curl -LO "https://dl.k8s.io/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl.sha256"
sudo echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
sudo chmod +x kubectl
sudo mkdir -p ~/.local/bin
sudo mv ./kubectl ~/.local/bin/kubectl
sudo kubectl version --client
sudo kubectl version --client --output=yaml   

# install terraform
sudo yum install -y yum-utils
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
sudo yum -y install terraform
