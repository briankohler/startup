#!/bin/bash  

TERRAFORM_VERSION=0.9.11
docker -v 2>&1 > /dev/null
ec=$?

echo "START-ME-UP"
echo "The goal of this project is to provide a production-ready, cloud-based set of environments"
echo "that, after bootstrapping, is ready to build and run applications.  The end-state goal is to"
echo "completely abstract the underlying operational concerns of developing software and running"
echo "applications in a manner that adheres to industry best-practices.  After running this script,"
echo "you can expect the following:"
echo "  - the script will prompt you for inputs specific to you, like AWS account id, desired subnets, etc."
echo "  - in the region selected, 4 VPCs will be created, ops, qa, stg, and prd."
echo "  - the 4 VPCs span a single /16 subnet, and each VPC is a /18 (1 quarter of the /16 supernet)"
echo "  - each VPC has its subnets spread across 2 availability zones"
echo "  - each VPC has 5 logical subnets, public, private, ephemeral, internal_vips, and data"
echo "  - of these 5 logical subnets, internal_vips and data are optionally created, but default to create=true"
echo "  - 2 base AMIs are created, CentOS 7.3 and Ubuntu 14.04, each with enhanced networking and ENI enabled"
echo "  - an OpenVPN node is created in ops that auto-connects your system to the private networks of the VPCs"
echo "  - either/both a Kubernetes cluster and/or a Nomad/Consul are created in each of the 4 vpcs (you choose)"
echo "  - a Jenkins master is created complete with template jobs to clone and re-use (only GoLang templates available)" 
echo "  - an S3-backed private Docker registry that is available on all hosts on localhost (read only) and read-write on the Jenkins node"
echo "  - examples of how both Puppet and Ansible could be used to provision systems"
echo
echo "There's more to come.  The end-state goal of this project includes the following:"
echo "  - creation of a production-built ELK stack for log aggregation and visualization"
echo "  - creation of an InfluxDB cluster that collects node metrics, fronted by Grafana for visualization"
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

echo "Checking docker-compose..."
VERSION=$(docker-compose -v)

if [ $? -ne 0 ]
then
  echo "Missing Docker-compose.  Installing with Homebrew"
  brew install docker-compose docker-compose-completion
else
  echo "Docker-compose version ${VERSION} already installed"
fi

echo "Checking Packer..."

PACKER_VERSION=$(packer -v)

if [ $? -ne 0 ] || [ "${PACKER_VERSION}" != "1.0.3" ]
then
  echo "Packer either missing or outdated.  Downloading Packer 1.0.3"
  curl -o packer.zip 'https://releases.hashicorp.com/packer/1.0.3/packer_1.0.3_darwin_amd64.zip?_ga=2.191845802.1256031939.1496791395-1073469743.1491481355'
  unzip packer.zip
  chmod +x packer 
  /bin/mv packer /usr/local/bin/
  rm packer.zip
  echo "Packer 1.0.3 installed"
fi

echo "Checking Terraform..."

INSTALLED_TERRAFORM_VERSION=$(terraform -v | cut -d" " -f2)

if [ $? -ne 0 ] || [ "${INSTALLED_TERRAFORM_VERSION}" != "v${TERRAFORM_VERSION}" ]
then
  echo "Terraform either outdated or missing. Downloading Terraform ${TERRAFORM_VERSION}"
  curl -o terraform.zip 'https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_darwin_amd64.zip?_ga=2.22939835.1200042640.1496791588-1012937137.1462542546'
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
sudo bash -xc "echo '127.0.0.1  git' >> /etc/hosts"
echo
echo "The repos folder of this repository is a bare repository that includes dozens of repos.  This is the foundation of everything StartMeUp"
echo "offers.  After everything builds, you'll end up with these repos running in a Gogs instance in your VPC.  You can easily mirror them to"
echo "GitHub or continue to use Gogs."
git clone repos/ git
cd git && docker-compose up -d && cd ..
while ! curl -s git:10080 2>&1 > /dev/null; do
  echo "Waiting for Gogs to start..."
  sleep 2
done
echo "Gogs is now running on your localhost.  The script will pause so you can review the repositories contained within.  You can login via a browser at http://git:10080 with username 'startup' and password 'startup'."
echo "Press any key to continue"
read -n 1

echo "Now, just a couple of questions..."
echo "What is your AWS Account ID?"
read account_id

echo "Choose a bucket prefix.  This string is prepended to bucket names to help ensure uniqueness. It can be left blank, but will likely lead to errors due to the globally unique nature of S3 buckets."
echo "Suggestion: Choose a unique string, eg., mytestcloud5293"
read bucket_prefix

echo "Part of this build involves creating Packer-defined base images. They are instantiated in the public subnet, thus SSH is restricted to only be allowed from your public IP."
echo "In addition, your public IP becomes also becomes part of the public network ACL, therefore, only your IP is allowed to access port 22 on all public subnets."
echo "For now, only your public IP is included in the configuration. Your IP is stored in an array, so after the initial environment build, you can add more IPs to this list if necessary."
echo "Finding your public IP..."
public_ip=$(dig +short myip.opendns.com @resolver1.opendns.com.)
echo "Your public IP is ${public_ip}"
echo "Adding ${public_ip}/32 to the ACL whitelist."
echo

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
  echo "In practice, very few users should have access to ths bucket, and it is generally best practice to only allow Jenkins or an analogous CI tool to have access."
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
  rm -rf infrastructure
  docker rm -f -v git_gogs_1
  exit 1
fi

echo "Do you have an existing DynamoDB tables in ${statebucket_region} to be used for Terraform state locking and consistency? (y or n)"
echo "This is to ensure collaboration between team members do not conflict by ensuring changes occur one at a time"
read -n 1 answer 

if [ "${answer}" == "y" ] || [ "${answer}" == "Y" ]
then
  echo "The table must have a primary key of LockID"
  echo "DynamoDB table name?"
  read dynamodb_table
elif [ "${answer}" == "n" ] || "${answer}" == "N" ]
then
  echo "Creating a DynamoDB table named terraform-state-locking in ${statebucket_region} with primary key LockID."
  aws dynamodb create-table --attribute-definitions AttributeName=LockID,AttributeType=S --key-schema AttributeName=LockID,KeyType=HASH --table-name terraform-state-locking --region ${statebucket_region} --provisioned-throughput ReadCapacityUnits=1,WriteCapacityUnits=1
  dynamodb_table=terraform-state-locking
else
  echo "invalid response. bailing"
  rm -rf infrastructure
  docker rm -f -v git_gogs_1
  exit 1
fi
  
echo
echo "While many implementations of Terraform use the state file(s) to reference previously-created, dependent resources in downstream configurations, this build takes a different approach.  Instead of requiring access to potentially sensitive state files, the Terraform code that generates root/foundational resources itself creates a Terraform module aptly named discovery.  This discovery module includes all relavent and necessary resource ids, bucket names, etc. generated.  The discovery module is then included in downstream Terraform configurations and is used to reference dependent root resources without exposing any state files or the buckets that contain them."
echo
echo "Press any key to continue..."
read -n 1

cat > infrastructure/global/state.tf << END
provider "aws" {
  region = "us-east-1"
}
terraform {
    required_version = "${TERRAFORM_VERSION}"
    backend "s3" {
        bucket = "${state_bucket}"
        encrypt = "true"
        key = "terraform-remote-state-global"
        region = "${statebucket_region}"
        dynamodb_table = "${dynamodb_table}"
    }
}
END

echo 'In which region would you like to build the VPC? Ensure that resource limits in this region are increased to allow 8 EIPs/NAT gateways to be provisioned'
read my_region

echo "4 VPCs will be provisioned in ${my_region}, each across 2 AZs, named ops,qa,stg,prd.  These names are not configurable yet, however, this feature will be available soon."
echo 'The 4 VPCs are organized in a hub-and-spoke model, with ops as the hub, and qa/stg/prd as the spokes.  Peering connections from ops to each of the other three allow traffic and DNS resolution to/from qa,stg,prd and ops, but never between each other to preserve isolation.'
echo 'Ops is the common VPC with which the others peer and is meant to house common/shared resources such as Jenkins/CI tools, log aggregation, metric collection tools, VPN access servers, and other analogous software.  Each VPC assumes a /18 subnet, carved out from a larger /16 subnet. Adding other subnet layout options is a feature that will be available soon, however, the ability to freely select any size subnet will not be possible, preferring instead to generate predictable, consistent networking patterns.'
echo
echo 'Specify the first two octets of the /16 network that will encompass the 4 VPCs (eg. 10.201)'
read supernet

cat > infrastructure/region/state.tf << END
provider "aws" {
  region = "\${var.region}"
}

terraform {
    required_version = "${TERRAFORM_VERSION}"
    backend "s3" {
        bucket = "${state_bucket}"
        encrypt = "true"
        key = "terraform-remote-state-region-${my_region}"
        region = "${statebucket_region}"
        dynamodb_table = "${dynamodb_table}"
    }
}
END

echo "region = \"${my_region}\"" > infrastructure/region/region.tfvars
echo "ip_supernet = \"${supernet}\"" >> infrastructure/region/region.tfvars
echo "num_azs = 2" >> infrastructure/region/region.tfvars

/bin/mv infrastructure/region infrastructure/${my_region}

echo "Naturally, an SSH private key is needed to access nodes provisioned.  One will be generated that will be reused in all environments and labeled the {env}-default_key.  After bootstrap, any resources provisioned with this key can easily be changed, both on the nodes themselves and/or the Terraform configuration that generated the node."
echo
echo "Generating ssh private and public SSH keys."
echo "Your private key is in ~/.ssh/startmeup.key and will be used to SSH to any nodes in this provisioning process."
echo "Note that for all AMIs built by this process, use ec2-user as the SSH username, regardless of distribution."

ssh-keygen -q -N "" -t rsa -f ~/.ssh/startmeup.key
chmod 600 ~/.ssh/startmeup.key

public_key=$(cat ~/.ssh/startmeup.key.pub)
echo "default_public_key = \"${public_key}\"" >> infrastructure/${my_region}/region.tfvars
echo
echo
echo "Also, injecting the public SSH key into Gogs under the startup user for authenticated cloning via SSH."
echo '{' > /tmp/key.json
echo '"title":"startup@gogs",' >> /tmp/key.json
echo "\"key\":\"$(cat ~/.ssh/startmeup.key.pub)\"" >> /tmp/key.json
echo '}' >> /tmp/key.json 
curl -s -XPOST "http://startup:startup@git:10080/api/v1/user/keys" -d @/tmp/key.json -H 'Content-Type: application/json'
echo
echo
echo "For now, internal DNS domains are pre-configured to be in the form {environment}-{region_nodash}.aws, ie, ops-uswest2.aws.  This will be configurable in future revisions." 
domain_suffix=$(echo $my_region | gsed 's/-//g').aws
sleep 10
echo
echo "Future revisions of this automation will lay the foundation for using an on-demand SSL certififate provisioning service such as LetsEncrypt.  This approach adheres best to best practices around handling SSL certificates and keys."
echo "As a default, self-signed wildcard SSL certificates/keys are generated, one per vpc, and stored in a separate secrets Git repo.  Future revisions will incorporate more sophisticated methods of handling secrets in general."
echo
sleep 10

cd infrastructure/${my_region} && git clone http://git:10080/secrets/terraform_secrets.git secrets && cd ../../

for i in qa stg prd ops
do
  openssl req -x509 -newkey rsa:2048 -keyout self-signed.key -out self-signed.pem -days 1825 -nodes -subj "/C=US/ST=California/L=Los Angeles/O=StartMeUp/OU=${i}/CN=*.${i}-${domain_suffix}"
  /bin/mv self-signed.* infrastructure/${my_region}/secrets/${i}/
done

cd infrastructure/${my_region}/secrets && git add --all && git commit -m 'create self-signed certs' && git push origin master && cd ../../../
rm -rf infrastructure/${my_region}/secrets

echo "Self-signed SSL certs/keys generated..."
sleep 5

echo
echo "Creating global and regional Terraform configurations.  The global configurations define resource that span all regions, which mostly constitutes common IAM roles and globally-scoped buckets.  Regional configurations include VPC resources, route53 zones, and regionally-scoped buckets.  These configurations will be committed to Gogs as the infrastructure repository."
echo "In some cases, a region must be specified for some global resources.  For these resources, us-east-1 is the reason chosen for reasons related to AWS infrastructure"
echo
sleep 10

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
    && git submodule update --remote --recursive --init && git add --all && git remote add origin http://git:10080/startup/infrastructure.git \
    && git commit -m 'initial commit' && git push -u origin master && cd ..

echo 'Again, ensure you have the ability to create 8 EIPS/NAT gateways in ${my_region} before proceeding.'
echo 'Requests for this usually fulfill in less than ten minutes.'
echo 'To avoid any issues, verify your limits in the selected region via the AWS console,'
echo 'and request an increase if necessary.'
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
sleep 5
echo
echo 'Creating the VPCs and base AMIs.'
echo 'This process is parallelized with Docker and uses Terraform environments, so there is going to be a lot of activity on the screen'
echo 'The ops VPC is created first and built using the Terraform binary installed on your laptop.'
echo 'Then, a script builds a container image that is instantiated 3 times in parallel, each provisioning one of qa, stg, and prd, respectively.'
echo 'While qa,stg,prd VPCs are provisioning, Packer on your local system creates the base CentOS 7.3 AMI and base Ubuntu-14.04 AMI on the ops public subnet.'
echo 'The process takes between 10-12 minutes to complete.'
echo
sleep 10

cd infrastructure/${my_region}
terraform init
terraform env new ops
terraform env select ops
terraform apply -var-file=region.tfvars -var create_base_image="true"
cd ../../

echo
echo "VPCs and base AMIs created"
echo
echo "Now creating the apps repository, which is nothing more than a repo of subrepos."
echo "The subrepos could be managed by various teams and could each have their own state bucket/files."
echo "However, in order to maintain an authoratative list of resources provisioned, these subrepos should"
echo "only be applied if included as submodules in the apps repo."
echo "This allows users to provision systems how they choose, while allowing for an operational inventory of"
echo "the software that is running and where it is running"
echo "Press any key to continue..."
read -n 1
echo
echo "Creating apps repository..."
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
    required_version = "${TERRAFORM_VERSION}"
    backend "s3" {
        bucket = "${state_bucket}"
        encrypt = "true"
        key = "apps/${my_region}-APPNAME"
        region = "${statebucket_region}"
        dynamodb_table = "${dynamodb_table}"
    }
}
END

echo "The first application in the apps repo will be OpenVPN.  The following Terraform run will"
echo "create an OpenVPN instance, load a configuration into your local instance of Tunnelblick, "
echo "and connect to the VPN."
echo "This is necessary because further node provisioning requires direct access to nodes in private"
echo "subnets, and this implmentation favors authenticated VPN to cumbersome bastion servers."
echo

cat state.tf.tmpl | sed 's/APPNAME/openvpn/g' > openvpn/state.tf
git add --all
git commit -m 'initial commit'
git remote add origin http://git:10080/startup/apps.git
git push -u origin master

echo
echo "App repo created and committed."
echo "Applying Terraform configuration for OpenVPN"
echo "You will be prompted for credentials when the VPN configuration is imported into Tunnelblick."
echo "After import, connect to the startmeup connection in Tunnelblick to complete the Terraform run"
echo "Press any key to continue..."
read -n 1

cd openvpn
terraform init
terraform env new ops
terraform env select ops
terraform apply -var use_extra_elb="true"
terraform apply

echo
echo "Now creating Kubernetes cluster and Nomad modules in the apps repo..."
echo "A Kubernetes cluster will be instantiated in each of the environments you choose"
echo "Again, the build will be parallelized using Docker such that all (up to) 4 clusters will be built simultaneously."
echo
echo "Provide a space-delimited list of environments in which to provision a Kubernetes cluster.  Leave empty for none"
read kube_envs
echo "Provide a space-delimited list of environments in which to provision a Nomad/Consul cluster.  If empty, one will be created in ops"
read nomad_envs

cd ../../
git submodule add http://git:10080/applications/kubernetes_cluster.git ${my_region}/kubernetes_cluster
git submodule add http://git:10080/applications/nomad.git ${my_region}/nomad
cd ${my_region}
cat state.tf.tmpl | sed 's/APPNAME/kubernetes_cluster/g' > kubernetes_cluster/state.tf
cat state.tf.tmpl | sed 's/APPNAME/nomad/g' > nomad/state.tf
git add --all
git commit -m 'adding kubernetes_cluster and nomad'
git push origin master

cd kubernetes_cluster
cp ~/.ssh/startmeup.key ssh.key
if [ "${kube_envs}" != "" ]
then
  echo "Creating Kubernetes clusters in ${kube_envs}"
  ./parallel_build.sh "${kube_envs}"
  for i in $kube_envs
  do
    echo "Opening Grafana and Kubernetes Dashboard for ${i} cluster..."
    sleep 2
    open https://admin:Welcome123@${i}-kubemastervip.${i}-${domain_suffix}:6443/api/v1/namespaces/kube-system/services/kubernetes-dashboard/proxy/
    open http://grafana.k8s.${i}-${domain_suffix}
  done
  echo "The dashboards are are protected by basic auth, username admin, password Welcome123, which should be changed."
  echo
  echo "The clusters have 3 masters each, on which Etcd is also running.  Each cluster starts out with 1 minion NOT in an autoscaling group and 1 nginx-based ingress also NOT in an autoscaling group. The masters are not part of an autoscaling group."
  echo
  echo "A wildcard DNS entry in each VPC *.k8s.{domain} points to the ingress node(s) and is intended to be the"
  echo "dedicated subdomain of Kubenetes applications exposed outside the clusters as ingresses."
  echo
  echo "Helm is also deployed in each cluster, in the event that a chart needs to be deployed."
  echo "Lastly, Heapster and InfluxDB are running on each cluster for collecting cluster metrics."
  echo "The inclusion of Heapster/InfluxDB is what exposes the graphs in the dashboard."
  echo "Grafana is also provisioned and is exposed as an ingress.  Grafana can be viewed at"
  echo "http://grafana.k8s.(ops|prd|qa|stg)-(region_nodash).aws"
  echo
else
  echo "Skipping creation of Kubernetes clusters"
fi

if [ "${nomad_envs}" == "" ]
then
  nomad_envs=ops
  echo "Defaulting to creating a Nomad/Consul cluster in ops"
else
  echo "Creating Nomad/Consul clusters in ${nomad_envs}"
fi

cd ../nomad
terraform init
for i in $nomad_envs
do
  terraform env new $i
  terraform env select $i
  terraform apply 
done

echo "Creating Jenkins master node"
echo "It can be reached at ops-jenkins001:8080"

cd ../../
git submodule add http://git:10080/terraform_services/jenkins ${my_region}/jenkins
cd ${my_region}
cat state.tf.tmpl | sed 's/APPNAME/jenkins/g' > jenkins/state.tf
git add --all
git commit -m 'adding jenkins'
git push origin master

cd jenkins
terraform init
terraform env new ops
terraform env select ops
terraform apply

echo "Next steps"
echo "K8s-Dynamic provisioning of EBS volumes to back InfluxDB"
echo "K8s-The minions and ingresses are not currently in asgs.  Provisioning is easier to create dedicated, standalone nodes first, then install Kube autoscaling bits, scripts for new nodes to auto-join an existing cluster"
echo "Provision EBS backed ES cluster that will collect logs inside and outside the pod, inside via fluentd and outside via logstash"
echo "Fix InfluxDB Ingress and wire up carbon-relay-ng on all nodes to relay metrics to InfluxDB"
echo "Adjust netdata to send metrics to InfluxDB ingress"
echo "Transfer Gogs repos from provisioner laptop to s3, stop Gogs on the laptop, and launch Gogs in Kubernetes with EBS storage"


