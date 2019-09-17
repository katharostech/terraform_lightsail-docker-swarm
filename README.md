# Terraform Lightsail Docker Swarm

A Terraform configuration file for standing up a Docker swarm on AWS Lightsail.

The configuration also installs Portainer and can point a Route53 DNS at the cluster so that you can access it.

## Dependencies

Unfortunately, due to the limitations of Terraform's lightsail resources, this terrafile needs the AWS cli installed and the default credentials need to be configured for the AWS account you are using.

## Usage

You will probably want to customize the deployment for how many servers you want and which size server, but by default it creates one manager and two worker nodes on the Lightsail nano instances. You will also want to change the DNS to a domain that you own so that it can point that DNS record to the cluster.

If there are any portions of the file that you don't need, such as portainer or DNS, you can set the `count = 0` instead of one and it will not be run.

After your customizations are done you can deploy it like this:

```
terraform init
terraform apply
```

When you are done with your cluster you can run `terraform destroy` to completely delete your cluster. BEWARE!! There is no undoing a `terraform destroy`; you cluster will be irrecoverable.

This was quickly put together for the purpose of being able to very quickly and cost effectively stand up Docker swarm clusters for testing. Using this you can have a complete Docker swarm in just a couple of minutes!

For now this README is a little sparse, but the terrafile is well commented and you will be able to find more guidance by looking at that. If you have any questions feel free to open an issue.
