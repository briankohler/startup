#!/bin/bash

echo "Which region is being destroyed?"
read region

echo "This will destroy everything in ${region}. Are you sure?"
read -n 1
echo "Are you sure you're sure?"
read -n 1

echo "Ok, destroy all the things in ${region}"
cd $region
terraform env select default
terraform destroy -force -var-file=region.tfvars

