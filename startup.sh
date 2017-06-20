#!/bin/bash 

docker -v 2>&1 > /dev/null
ec=$?

echo "START-ME-UP"
echo "The goal of this project is to provide a production-ready, cloud-based set of environments"
echo "that, after bootstrapping, is ready to build an run applications.  The end-state goal is to"
echo "completely abstract the underlying operational concerns of developing software and running"
echo "applications in a manner that adheres to industry best-practices.  After running this script,"
echo "you can expect the following:"
echo "  - the script will prompt you for inputs specific to you, like AWS account id, desired subnets, etc."
echo "  - in the region selected, 4 VPCs will be created, ops, qa, stg, and prd."
echo "  - the 4 VPCs span a single /16 subnet, and each VPC is a /18 (1 quarter of the /16 supernet)"
echo "  - each VPC is spread across 2 availability zones"
echo "  - each VPC has 6 logical subnets, public, private, ephemeral, internal_vips, and data"
echo "  - of these 6 logical subnets, internal_vips and data are optionally created, but default to create=true"
echo "  - 2 AMIs are created, CentOS 7.3 and Ubuntu 14.04, each with enhanced networking and ENI enabled"
echo
echo "There's more to come.  The end-state goal of this project includes the following:"
echo "  - creation of a production-built ELK stack for log aggregation and visualization"
echo "  - creation of a either (or both) a Kubernetes cluster and/or a Nomad cluster in each VPC"
echo "  - creation of a Jenkins master with pre-populated template jobs intended to be cloned/re-used"
echo "  - creation of an S3-backed private Docker repository for image storage and distribution"
echo "  - creation of an InfluxDB cluster that collects node metrics, fronted by Grafana for visualization"
echo "  - a Puppet-driven method for application deployment and configuration management"
echo "  - a vault-driven method for secrets management that does not require integrating applications with vault directly"
echo "  - this will all span more than 1 cloud provider"
echo
echo "Let's get started"
echo "Press any key to continue..."
read -n 1

if [ ! -f ~/.aws/credentials ]
then
  echo "Please create a default AWS credentials file - ~/.aws/credentials - that has full admin access to the AWS account"
  exit 1
fi

echo "Checking Docker installation..."

if [ $ec -ne 0 ]
then
  echo "Docker not installed. Downloading.  You may be prompted for sudo creds"
  curl -o /tmp/docker.dmg 'https://download.docker.com/mac/edge/Docker.dmg'
  echo "Mounting DMG.  Kindly drag and drop."
  sudo hdiutil attach /tmp/docker.dmg
  echo "press any key after docker is installed"
  read -n 1
  sudo hdiutil detach /Volumes/docker
fi

VERSION=$(docker -v)

echo "${VERSION}" | grep 17 | grep ce > /dev/null

if [ $? -ne 0 ]
then
  echo "Docker version ${VERSION} is pretty old.  Please upgrade"
  exit 1
else
  echo "Docker version ${VERSION} already installed"
fi

echo "Checking Packer..."

PACKER_VERSION=$(packer -v)

if [ $? -ne 0 ] || [ "${PACKER_VERSION}" != "1.0.0" ]
then
  echo "Packer either missing or outdated.  Downloading Packer 1.0.0"
  curl -o packer.zip 'https://releases.hashicorp.com/packer/1.0.0/packer_1.0.0_darwin_amd64.zip?_ga=2.191845802.1256031939.1496791395-1073469743.1491481355'
  unzip packer.zip
  chmod +x packer 
  /bin/mv packer /usr/local/bin/
  rm packer.zip
  echo "Packer ${PACKER_VERSION} installed"
fi

echo "Checking Terraform..."

TERRAFORM_VERSION=$(terraform -v | cut -d" " -f2)

if [ $? -ne 0 ] || [ "${TERRAFORM_VERSION}" != "v0.9.8" ]
then
  echo "Terraform either outdated or missing. Downloading Terraform 0.9.8"
  curl -o terraform.zip 'https://releases.hashicorp.com/terraform/0.9.8/terraform_0.9.8_darwin_amd64.zip?_ga=2.22939835.1200042640.1496791588-1012937137.1462542546'
  unzip terraform.zip
  chmod +x terraform
  /bin/mv terraform /usr/local/bin/
  rm terraform.zip
  echo "Terraform installed/updated"
fi

echo "Checking jq..."
brew install jq 
brew upgrade jq
echo "Checking aws-cli..."
brew install awscli
brew upgrade awscli
echo "Checking gnu-sed..."
brew install gnu-sed
brew upgrade gnu-sed

echo "PRE-REQS INSTALLED!!!"
echo

echo "We're going to create an instance of git locally that runs with Gogs as a frontend.  It's very similar to Github."
echo "To make things easier, we're going to insert a host file record pointing 'git' to 'localhost'. You'll be prompted for credentials"
echo
sudo bash -c "echo '127.0.0.1  git' >> /etc/hosts"
echo
echo "The repos folder of this repository is a bare repository that includes dozens of repos.  This is the foundation of everything StartMeUp"
echo "offers.  After everything builds, you'll end up with these repos running in a Gogs instance in your VPC.  You can easily mirror them to"
echo "GitHub or continue to use Gogs."
git clone repos/ git
cd git && docker-compose up -d && cd ..
echo "Gogs is now running on your localhost.  You can login via a browser at http://git:10080 with username 'startup' and password 'startup'."
echo "Press any key to continue"
read -n 1

echo "Now, just a couple of questions..."
echo "What is your AWS Account ID?"
read account_id
echo "Choose a bucket prefix.  This string is prepended to bucket names to help ensure uniqueness. It can be left blank, but will likely lead to errors."
echo "Suggestion: Choose a unique string, eg., bkstartmycloud"
read bucket_prefix

echo "To build the initial base image, we restrict SSH to only be allowed from your public IP in the security group"
echo "Also, your public IP becomes part of the public network ACL, therefore, only your IP is allowed to access port 22 on all public subnets"
echo "For now, we'll just use your public IP, but the variable is an array, so several CIDRs can be listed."
echo "Finding your public IP..."
public_ip=$(dig +short myip.opendns.com @resolver1.opendns.com.)
echo "Adding ${public_ip}/32 to the ACL whitelist. More addresses can be added later."

mkdir -p infrastructure/{global,region}
echo '.terraform' > infrastructure/.gitignore
echo 'terraform.tfstate*' >> infrastructure/.gitignore
echo "account_id = \"${account_id}\"" > infrastructure/global/terraform.tfvars
echo "external_subnet = [\"${public_ip}/32\"]" >> infrastructure/global/terraform.tfvars
echo "iam_profile = \"ec2_readonly\"" >> infrastructure/global/terraform.tfvars
echo "bucket_prefix = \"${bucket_prefix}\"" >> infrastructure/global/terraform.tfvars
cd infrastructure && ln -s global/terraform.tfvars global.tfvars && cd ..

echo 'Do you already have a bucket with versioning enabled for Terraform state files? (Answer y or n)'
read -n 1 answer

if [ "${answer}" == "y" ] || [ "${answer}" == "Y" ]
then
  echo 'State bucket name?'
  read state_bucket
  echo 'State bucket region?'
  read statebucket_region
elif [ "${answer}" == "n" ] || "${answer}" == "N" ]
then
  echo "Creating a state bucket"
  echo "This is the only manually provisioned, unmanaged resources in the entire stack."
  echo "This is INTENTIONAL due to the sensitive nature of the contents of state files."
  echo "In practice, very few users should have access to ths bucket, and really, only Jenkins should have access"
  echo 
  echo 'In which region should your state bucket reside?'
  read statebucket_region
  echo 'Provide a bucket name for your state bucket, eg. name-terrraform-tfstates.'
  read state_bucket
  echo "creating bucket ${state_bucket} in ${statebucket_region} and enabling versioning..."
  aws s3 mb s3://${state_bucket} --region ${statebucket_region}
  aws s3api put-bucket-versioning --bucket $state_bucket --versioning-configuration Status=Enabled --region ${statebucket_region}
else
  echo "invalid response. bailing"
  exit 1
fi

cat > infrastructure/global/state.tf << END
provider "aws" {
  region = "us-east-1"
}
terraform {
    required_version = "0.9.8"
    backend "s3" {
        bucket = "${state_bucket}"
        encrypt = "true"
        key = "terraform-remote-state-global"
        region = "${statebucket_region}"
    }
}
END

echo 'Which region would you like to build in?  The region must have ECS available and have limits increased to allow 8 EIPs/NAT Gateways to provision (eg. us-west-2)'
read my_region

echo 'We will be deploying 4 VPCs across 2 AZs, named ops,qa,stg,prd.  These names are not configurable yet, but will be soon.'
echo 'The 4 VPCs are organized in a hub-and-spoke model, with ops as the hub, and qa/stg/prd are the spokes.  Peering connections from ops to each of the other three allow traffic to from from environments to/from ops, but never to each other to preserve isolation'
echo 'Ops is the common VPC with which the others peer.  Each VPC is a /18 subnet, carved out from a larger /16 subnet'
echo 'Specify the first two octets of the /16 network that encompasses all 4 VPCs (eg. 10.201)'
read supernet

cat > infrastructure/region/state.tf << END
provider "aws" {
  region = "\${var.region}"
}

terraform {
    required_version = "0.9.8"
    backend "s3" {
        bucket = "${state_bucket}"
        encrypt = "true"
        key = "terraform-remote-state-region-${my_region}"
        region = "${statebucket_region}"
    }
}
END

echo "region = \"${my_region}\"" > infrastructure/region/region.tfvars
echo "ip_supernet = \"${supernet}\"" >> infrastructure/region/region.tfvars
echo "num_azs = 2" >> infrastructure/region/region.tfvars

/bin/mv infrastructure/region infrastructure/${my_region}

echo "You, of course, need a private key.  For now, this will generate one that is used for all environments"
echo "After bootstrap, you can easily vary the public key per environment"
echo "However, it should be noted that, when Puppet/cfg mgmt is incorporated, it will assume the responsibility of managing user"
echo "ssh keys on a per-node level and configured in hiera."
echo "Generating ssh private and public keys for SSH access to nodes."
echo "Your private Key is in ~/.ssh/startmeup.key. For all AMIs built by this process, use ec2-user as the SSH username"

ssh-keygen -q -N "" -t rsa -f ~/.ssh/startmeup.key
chmod 600 ~/.ssh/startmeup.key

public_key=$(cat ~/.ssh/startmeup.key.pub)
echo "default_public_key = \"${public_key}\"" >> infrastructure/${my_region}/region.tfvars

echo "Injecting the public key into Gogs too"
echo '{' > /tmp/key.json
echo '"title":"startup@gogs",' >> /tmp/key.json
echo "\"key\":\"$(cat ~/.ssh/startmeup.key.pub)\"" >> /tmp/key.json
echo '}' >> /tmp/key.json 
curl -s -XPOST "http://startup:startup@git:10080/api/v1/user/keys" -d @/tmp/key.json -H 'Content-Type: application/json'

domain_suffix=$(echo $my_region | gsed 's/-//g').aws
echo "SSL is not yet handled by this repo, but will be soon, and will be done using an on-demand SSL cert provisioning service,"
echo "as this approach adheres best to best practices around handling sensitive information."
echo "For now, we're just going to generate *.{private-dns-domain} self-signed certs and store them in a secrets subfolder"

cd infrastructure/${my_region} && git clone http://git:10080/secrets/terraform_secrets.git secrets && cd ../../

for i in qa stg prd ops
do
  openssl req -x509 -newkey rsa:2048 -keyout self-signed.key -out self-signed.pem -days 1825 -nodes -subj "/C=US/ST=California/L=Los Angeles/O=StartMeUp/OU=${i}/CN=*.${i}-${domain_suffix}"
  /bin/mv self-signed.* infrastructure/${my_region}/secrets/${i}/
done

cd infrastructure/${my_region}/secrets && git add --all && git commit -m 'create self-signed certs' && git push origin master && cd ../../../
rm -rf infrastructure/${my_region}/secrets

cat > infrastructure/global/iam.tf << END
variable "account_id" {}
variable "region" {
  default = "us-east-1"
}
variable "bucket_prefix" {}

module "iam" {
  source = "git::http://git:10080/terraform_modules/iam.git"
  account_id = "\${var.account_id}"
  bucket_prefix = "\${var.bucket_prefix}"
}
END

cd infrastructure/${my_region} && ln -s ../global.tfvars terraform.tfvars && cd ../../

cat > infrastructure/${my_region}/${my_region}-services.tf << END
variable "account_id" {}
variable "region" {}
variable "num_azs" {}
variable "ip_supernet" {}
variable "default_public_key" {}
variable "create_base_image" {
  default = "false"
}
variable "external_subnet" {
  type = "list"
}

module "vpc" {
  source = "git::http://git:10080/terraform_services/vpc.git"
  account_id = "\${var.account_id}"
  environment = "\${terraform.env}"
  use_data_subnets = "true"
  external_subnet = "\${var.external_subnet}"
  use_internal_vips_subnets = "true"
  region = "\${var.region}"
  num_azs = "\${var.num_azs}"
  ip_supernet = "\${var.ip_supernet}"
  default_public_key  = "\${var.default_public_key}"
  selfsigned_cert = "./secrets/\${terraform.env}/self-signed.pem"
  selfsigned_key = "./secrets/\${terraform.env}/self-signed.key"
}

module "base_image" {
  source = "./base_image"
  region = "\${var.region}"
  environment = "\${terraform.env}"
  create_base_image = "\${var.create_base_image}"
  public_subnet_ids = "\${module.vpc.public_subnet_ids}"
  security_group_id = "\${module.vpc.default_sg_id}"
  nat_gateway_ips = "\${module.vpc.nat_gateway_ips}"
}
END

curl -s -XPOST 'http://startup:startup@git:10080/api/v1/user/repos' -d '{ "name": "infrastructure","private": true }' -H 'Content-Type: application/json'

cd infrastructure && git init && git submodule add http://git:10080/secrets/terraform_secrets ${my_region}/secrets \
    && git submodule add http://git:10080/terraform_modules/base_image ${my_region}/base_image && git submodule init \
    && git submodule update --remote --recursive && git add --all && git remote add origin http://git:10080/startup/infrastructure.git \
    && git commit -m 'initial commit' && git push -u origin master && cd ..

echo 'Again, ensure you have the ability to create 8 EIPS/NAT gateways before proceeding.'
echo 'Requests for this usually fulfill in less than ten minutes.'
echo 'To avoid any issues, verify your limits in the selected region via the AWS console,'
echo 'and request an increase if necessary'
echo 'Press any key to start-up!'
read -n 1

echo
echo '------------------------------------------------------'
echo 'Setting up globally-scoped resources (common IAM roles)'
echo '------------------------------------------------------'
sleep 2
cd infrastructure/global
terraform init
terraform apply
cd ../../

echo
echo 'IAM Roles created'
echo
echo 'Creating the VPCs and base AMI'
echo 'This process is parallelized with Docker and uses Terraform environments'
echo 'The ops VPC is created first and built using the Terraform binary installed on your laptop'
echo 'Then, a script builds a container that is instantiated 3 times in parallel, each provisioning qa,stg,prd respectively'
echo 'While qa,stg,prd VPCs are provisioning, Packer on your local system creates the base CentOS 7.3 AMI and base Ubuntu-14.04 AMI'
echo 'on the ops public subnet.'
echo 'The process takes between 10-12 minutes to complete.'
echo
sleep 3

cd infrastructure/${my_region}
terraform init
terraform env new ops
terraform env select ops
terraform apply -var-file=region.tfvars -var create_base_image="true"
cd ../../

echo
echo "VPCs created"
echo
echo "Now we create the application repo, which is nothing more than a repo of subrepos"
echo "More than anything, the purpose of organizing like this gives some sense of what"
echo "is out there."
echo "Press any key to continue..."
read -n 1
echo
curl -s -XPOST 'http://startup:startup@git:10080/api/v1/user/repos' -d '{ "name": "apps","private": true }' -H 'Content-Type: application/json'
mkdir -p apps/${my_region} 
cd apps
git init
git submodule add http://git:10080/applications/openvpn.git ${my_region}/openvpn

cd ${my_region}
cat > discovery.tf << END
variable "bucket_prefix" {
  default = "${bucket_prefix}"
}
variable "vpn_cidrs" {
  type = "list"
  default = []
}
variable "region" {
  default = "${my_region}"
}

module "discovery" {
  source = "git::http://git:10080/terraform_modules/discovery.git"
  environment = "\${terraform.env}"
  region = "\${var.region}"
  bucket_prefix = "\${var.bucket_prefix}"
  vpn_cidrs = "\${var.vpn_cidrs}"
}
END

cat > state.tf.tmpl << END
terraform {
    required_version = "0.9.8"
    backend "s3" {
        bucket = "${state_bucket}"
        encrypt = "true"
        key = "apps/${my_region}-APPNAME"
        region = "${statebucket_region}"
    }
}
END

cat state.tf.tmpl | sed 's/APPNAME/openvpn/g' > openvpn/state.tf
git add --all
git commit -m 'initial commit'
git remote add origin http://git:10080/startup/apps.git
git push -u origin master

echo
echo "App repo created and committed."
echo "It contains 1 application, openvpn, which we will now apply and connect you to via Tunnelblick"
echo "Press any key to continue..."
read -n 1

cd openvpn
terraform init
terraform env new ops
terraform env select ops
terraform apply -var use_extra_elb="true"
terraform apply

echo
echo "Now creating Kubernetes cluster..."
echo

cd ../../
git submodule add http://git:10080/applications/kubernetes_cluster.git ${my_region}/kubernetes_cluster
cd ${my_region}
cat state.tf.tmpl | sed 's/APPNAME/kubernetes_cluster/g' > kubernetes_cluster/state.tf
git add --all
git commit -m 'adding kubernetes_cluster'
git push origin master

cd kubernetes_cluster
cp ~/.ssh/startmeup.key ../
./parallel_build.sh

