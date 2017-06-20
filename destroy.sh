#!/bin/bash

echo "Which region is being destroyed?"
read region

echo "This will destroy everything in ${region}. Are you sure?"
read -n 1
echo "Are you sure you're sure?"
read -n 1

echo "Ok, destroy all the things in ${region}"
cd infrastructure/$region
terraform init
terraform env select default
terraform destroy -force -var-file=region.tfvars

echo "Do you want to destroy the global resources?"
read -n 1

echo "Ok, destroying global resources..."
cd ../global
terraform init
terraform destroy -force 
