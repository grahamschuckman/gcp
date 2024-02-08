# GCP Wiz Dev Infra and Tech Challenge Overview
This is my write-up, notes, and Terraform for the Wiz Tech Challenge. It was advised to build in an environment that one is less familiar with, but since I have never worked with Kubernetes before, I chose to deploy in AWS using EKS and put on some extra bells and whistles.

There are a series of objectives to complete:
1. Build and deploy a functioning web application on an EKS cluster
    - I chose to use the Tasky app provided here:
    https://github.com/jeffthorne/tasky
    - The application must be built and deployed as a container
2. Build a database tier running an older version of MongoDB on an older version of Linux
    - This database needs to use the connection string for authentication and be provisioned on a VM/instance
    - It should have scripted back-ups that are sent to a separate storage location (bucket)
    - Access open to the Kubernetes cluster
    - The instance profile should have broad permissions
3. Build a storage tier to hold the MongoDB backups
    - This should be publicly readable and use secure methods for transferring data (SSL)
4. Provide public access to the compute resources of the EKS cluster using a load balancer
5. Provide the containers (pods) with cluster-admin privileges as identified here:
    - https://kubernetes.io/docs/reference/access-authn-authz/rbac/

## Approach
I started by first constructing the simpler components, namely, the EC2 instance that would run MongoDB, in Terraform. Since the resources were fairly basic, just the instance, instance profile, and the security groups, I packaged them all into one module called "ec2" and did not rely on external modules. The user data portion proved trickier than expected, since I wanted the entire database installed, plus authentication, without any manual user input.
  - In retrospect, I could have launched a blank Ubuntu 20.04 instance, installed the software, and built an AMI, but that would mean I would need a new AMI or additional user data as I made changes.
  - I selected Ubuntu 20.04 instead of Amazon Linux 2023 because I wanted to challenge myself with a Linux distro that I was less familiar with. Plus, I know Ubuntu 22.04 has been released, so this version is out-of-date.

Learning how to install and populate MongoDB with test data was fortunately not too difficult, and the links to the resources I followed are down below.

In between configuring the instance, I built out modules for S3 storage of the backups, the EKS cluster, and WAF as well. The EKS cluster was challenging as I opted to use local-exec to install things like the ALB ingress controller resources. Learning the IAM plane of EKS also took some time, as I had to understand how roles and service accounts mapped to IAM role in AWS.
  - Most of these WAFs have `count` or `for_each` structures so that additional resources can be deployed inside of them.
  - I chose to build a WAF module to show some additional security tooling that I was familiar with in AWS. It has basic AWS managed rules, and some custom ones, such as allowing traffic if the Referer header contains `securityheaders.com` so that I could do security scans.
  - For the S3 and EKS modules, I did use some community-based modules for the bucket, ACM cert and validation records, and Route53 entries.

Getting the actual application set up was not too bad either, as I chose to use the Tasky app after my custom Flask app, which worked locally and on different EC2 instances, would not work on the EKS cluster once packaged into a container. I opted to focus more on the infrastructure than the application, and thus chose the custom app.
  - I am particularly happy with my use of AWS SSM Parameter Store to ensure that no credentials to the database or the JWT secret key are in plain-text. Those values are all fetched at build or run.

To run all of this Terraform and my app code, I built a separate repo and build project called `schuckman-devops-build-infra` that maintains all of the CodeCommit repos, CodeBuild projects, ECR repositories, and related resources.
  - On some of these builds, I installed [Anton Babenko's pre-commit](https://github.com/antonbabenko/pre-commit-terraform) to run TFLint, tfsec, and check for terraform-docs. More details are listed in the [To-Do](#To-Do) section below.
  - I also used `bumpversion` on the shared module I created for IAM roles called `schuckman-devops-iam-role` so that ref tagging could be used.
  - I chose to separate infra and app repos and builds to reflect the realities of infra and application code often changing independent of one another. This also allows for better permission scoping.

For the actual application, I left the Dockerfile mostly untouched. I did run a `COPY` command to get the `wizexercise.txt` file onto the container, and I also ran `apk update` and `apk upgrade` to improve its security posture.

For the Nginx image, I wrote a custom `nginx.conf` file that turns off the logging of ALB health checks (too much noise) and adds in a CSP and some other basic security features. This was checked against [securityheaders.com](https://securityheaders.com) to get a passing grade of A. [The report can be seen here.](https://securityheaders.com/?q=dev.wiz.grahamschuckman.com&followRedirects=on)

To ensure my website looked legit, I created a Route53 Alias A record with the DNS name of the ALB created by the ingress controller. I associated a certificate with it as well.

For the ALB ingress controller, I made sure to do the following:
  - Redirect HTTP to HTTPS with a 301 response
  - Listen on port 80 and port 443 only
  - Check health on the /health path that Nginx will suppress

The actual deployment was written in a single .yml file called `wiz-dev-app-deployment.yml` and applied via local-exec with the command `kubectl apply -f wiz-dev-app-deployment.yml`

## Tradeoffs and Gotchas
Due to this being my first real foray into Kubernetes, the environment is not as locked down as I would like. I plan on diving deeper into the various private and public options for the cluster endpoints, as well as better understanding how the annotations perform role mapping between K8s and AWS IAM.

Some values, such as the certificate ARN and the DNS name, were also hardcoded after creation. This increases the likelihood of a deployment failure if those resources were destroyed or recreated. I am aware that Helm might help solve these problems and simplify the ingress controller installation as well, but have not yet explored it.

The private IP of the MongoDB database is harcoded into the `MONGODB_URI` environment variable passed to the Tasky app. This is probably my greatest annoyance, as I tried associating a public EIP with the database, but the app would not work. Future troubleshooting and brainstorming will be done, with some ideas already in the [To-Do](#To-Do) section below.

Logging was an area I could get around by using the `kubectl logs <pod-name>` command, but I would like to integrate the EKS resources with CloudWatch. For simplicity, I have only enabled some add-ons manually in the console.

Setting up this repo as part of a multi-account module would be outstanding. I have done this before, though since I currently only have one account, and the resources in this repo are for a particular stage, I chose not to do this.

I would have liked to use DocumentDB instead of MongoDB since I do not like the overhead that comes with running instances. This could be configured in a new version, but was required for this challenge.

## Intentional Security Misconfigurations
Per the requirements of the tech challenge, there were a number of potential security misconfigurations:
1. Highly privleged EC2 instance profile:
    - This is a violation of least privilege and a major source of concern if the instance were to be compromised.
    - Often an instance only needs permissions for SSM connectivity and maybe a few other services for the apps that run on it.
2. Publicly readable S3 bucket:
    - This is not a good practice, especially not without CloudFront fronting the requests. Buckets should typically block public access unless configured explicitly for public storage or something like a static website. Database backups absolutely do not fall into that category.
3. Out-of-date instance image and MongoDB version:
    - Also not a good practice, if it can be avoided. Keeping software up-to-date promotes better security with the latest patches, and reduces tech debt by preventing re-platforming down the road.
4. Giving the container `cluster-admin` privileges:
    - Again, asking for trouble. Stick to least privilege and no not modify the ServiceAccount `default` if it can be helped.

## Future Improvements
I would like to explore setting up TLS with MongoDB, as I know it can be added in the connection string when provided with a cert file.

OIDC integration with the Tasky app and the ALB would be interesting. Okta is one IdP provider that plays nice with AWS, despite their own security mishaps.

Helm would be fantastic to integrate into this deployment. I know ArgoCD works well with Helm for a full DevOps CI/CD pipeline as well.

Improving some development standards and naming conventions will save headache down the road. I could opt for something like `<project>-<dev>-<resource>`.

## Reflections
Overall, I felt this was a good assessment of AWS capabilities and an excellent method by which to learn the basics of EKS. I look forward to continuing to learn and grow, and I'll be taking a stab at launching this in GCP next!

# Linux Notes
"al2023-ami-2023.1.20230912.0-kernel-6.1-x86_64" - Older Version of AL2

"al2023-ami-2023.2.20231113.0-kernel-6.1-x86_64" - Newer Version of AL2

## Way to find older AMIs
`aws ec2 describe-images --filters "Name=name,Values=*al2023-ami-2023*" "Name=is-public,Values=true" --query "sort_by(Images, &CreationDate)[].[Name,ImageId]"`

## Install pip3 on Ubuntu
`sudo apt install python3-pip`

## Install Flask on Ubuntu
`pip3 install Flask`

## Test Flask app to run on the Ubuntu instance that allows connection from all IPs
```
from flask import Flask

app = Flask(__name__)

@app.route('/')
def hello_world():
    return 'Hello, Flask!'

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8000, debug=True)
```

## Should probably create a requirements.txt and use Python virtual environment for getting all the packages
`pip3 freeze > requirements.txt` (can also do https://stackoverflow.com/questions/31684375/automatically-create-file-requirements-txt)

## Install go on Ubuntu
## Documentation: https://go.dev/doc/install
`sudo curl -L -o go1.21.4.linux-amd64.tar.gz https://go.dev/dl/go1.21.4.linux-amd64.tar.gz`

# MongoDB Notes
## Install MongoDB on Ubuntu 20.04 ami-06aa3f7caf3a30282
https://www.mongodb.com/docs/v6.0/tutorial/install-mongodb-on-ubuntu/


## Get info from mongodb
`cat /etc/mongod.conf`

## Collections are basically tables that hold documents, which are akin to records for a RDBMS

## Mention that we could do IPv6 support 
`net.ipv6 : true`

## Needed to open up bindIp to all IP addresses: 0.0.0.0 (not a fan of this, but works for now)
## Tried using only the CIDR range of the VPC, but mongodb did not like the /20 at the end
https://docs.aws.amazon.com/dms/latest/sbs/chap-mongodb2documentdb.02.html

## Follow the mongodb logs as I test curling from another instance
`sudo tail -f /var/log/mongodb/mongod.log`

## Import data into mongodb so I can test querying it with a Flask app
`mongoimport --host localhost:27017 --db zips-db --file zips.json`

## Get data into a mongodb database for test querying:
https://docs.aws.amazon.com/dms/latest/sbs/chap-mongodb2documentdb.02.html

## List databases using mongosh (or use `show databases`):
```
db.adminCommand(
   {
     listDatabases: 1
   }
)
```

## List collections using mongosh:
`db.runCommand( { listCollections: 1 } )`

## Switch to a specific database in mongodb:
`use <db-name>`

## Get one item from the collection (replace myCollection with collection name, ex: zips):
`db.myCollection.findOne({}) --> db.zips.findOne({})`

## Was going to just use the regular DLM or AWS Backup services, but realized those backups do not go into a bucket that I can access
https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/EBSSnapshots.html

## Decided to use a cron job to schedule a mongodb dump (mongodump) into a tar file and put that into S3 instead
https://www.mongodb.com/docs/manual/tutorial/backup-and-restore-tools/

## Restore from mongodb backup file (since local, no need to specify hostname and port)
`mongorestore --verbose --db zips-db /home/ubuntu/backups/zips-db`

## Create a user for authentication in mongodb using `mongosh` with a preset password
```
db.createUser({
  user: "adminUser",
  pwd: "adminPassword",
  roles: ["root"]
})
```

## Create a user for authentication in mongodb using `mongosh` and have it prompt for a password
```
db.createUser({
  user: "adminUser",
  pwd: passwordPrompt(),
  roles: ["root"]
})
```

## Log into mongosh after turning on authentication (can use --authenticationDatabase <db-name>)
`mongosh -u <username>`

## Use standard connectiong string format to authenticate to mongodb
`mongodb://username:password@localhost:27017/mydatabase`

Make sure to specify the authentication database as well if necessary

`mongodb://username:password@<host-ip-address>:27017/zips-db?authSource=admin`

Full command when authenticating locally to the shell:

`mongosh "mongodb://username:password@<host-ip-address>:27017/zips-db?authSource=admin"`

# GCP Notes

## Display current region

## Tutorial for Basic Container Deployment
https://cloud.google.com/kubernetes-engine/docs/quickstarts/deploy-app-container-image?cloudshell=false#python

## Use the GCP SDK to push code from local Git repo to the gcloud Private Source Repository
https://source.cloud.google.com/kubernetesterraform-407803/wiz-dev-app?authuser=2&hl=en

## Get gcloud Project ID
`gcloud config get-value project`

## Basic HelloWorld Service
https://cloud.google.com/kubernetes-engine/docs/samples/container-helloapp-service?hl=en

## Basic HelloWorld Deployment
https://cloud.google.com/kubernetes-engine/docs/samples/container-helloapp-deployment?hl=en

## List objects in Google Cloud Storage bucket
`gsutil ls gs://your-bucket-name/`

## Copy object from local to Google Cloud Storage bucket
`gsutil cp /path/to/local/file.txt gs://your-bucket-name/`

## Make all objects in Google Cloud Storage bucket publicly readable
https://cloud.google.com/storage/docs/access-control/making-data-public#:~:text=In%20the%20list%20of%20buckets,Grant%20access%20dialog%20box%20appears.

## Use Cloud Run and create a Cloud Build yaml config file
https://cloud.google.com/build/docs/deploying-builds/deploy-cloud-run


## Allow VPC firewall rule for inbound traffic to MongoDB from GKE cluster nodes
Weird that you cannot do it to individual instances easily. Seems to be more applied at the VPC level.
`gcloud compute --project=kubernetesterraform-407803 firewall-rules create allow-mongodb-inbound-from-gke --description="Allow inbound traffic from GKE nodes to MongoDB over port 27017 and ICMP." --direction=INGRESS --priority=1000 --network=default --action=ALLOW --rules=tcp:27017,icmp --source-ranges=10.94.128.0/17`

## Associate static IP address from service or ingress with domain name in GKE
https://cloud.google.com/kubernetes-engine/docs/tutorials/configuring-domain-name-static-ip?_ga=2.145338164.-1687914125.1702268716

## Needed to associate a service account with the GCP Compute Engine VM running MongoDB
Required access to Storage for Read Write permissions so it could talk to the bucket for backups.

## Used a custom metadata startup-script to install MongoDB and configure the VM
Was able to use the same one as I did for the AWS instance and then SSHd onto the box and fixed some things manually.

# Kubernetes Notes

## Not sure why the official Terraform EKS cluster module was giving me so much trouble. Will just build the resources by hand.
Helps me learn better anyways.

## Should have better thought out the naming conventions for my vpc and subnets
Make it easier by calling the vpc "wiz" and the subnets "wiz-public-#" or "wiz-public-#"

## Need to update my local context to the AWS EKS cluster
`aws eks update-kubeconfig --region us-east-1 --name wiz-dev-cluster`

## Would like to better understand how to integrate my deployments, services, and pods into Terraform

## Are there other providers I can and should be using? What about Helm charts?
Currently just using a local exec to perform the kubectl apply, and then a data source to pick up the load balancer if necessary

## View the kubeconfig file
`kubectl config view`

## Change namespaces when using kubectl
`kubectl config set-context --current --namespace=<namespace-name>`

## View logs on a specific pod for all containers
`kubectl logs 2048-pod --all-containers=true`

## Get a shell on a pod
`kubectl exec -it <pod-name> -- sh`

## Verify that the pod's ServiceAccount has cluster admin permissions by viewing pod details
```
# Check the token file path
TOKEN_PATH=/var/run/secrets/kubernetes.io/serviceaccount/token
echo "Service Account Token:"
cat $TOKEN_PATH
```

```
# Use the token to query the Kubernetes API
APISERVER="https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_PORT_443_TCP_PORT"
wget --quiet --header="Authorization: Bearer $(cat $TOKEN_PATH)" --no-check-certificate -O - $APISERVER/api/v1/pods
```

## For setting up the ALB Ingress Controller (make sure to tag public subnets as key: kubernetes.io/role/elb value: 1 first)

## Tagging of the cluster's private subnets did not seem necessary. Will check other clusters to validate

## Documentation and video tutorial: https://repost.aws/knowledge-center/eks-alb-ingress-controller-setup
```
aws eks describe-cluster --name <cluster-name> --query "cluster.identity.oidc.issuer" --region us-east-1

aws iam list-open-id-connect-providers | grep <alpha-numeric-string-from-last-part-of-above-command> --> output will likely be blank if first time setting up

eksctl utils --region <region> associate-iam-oidc-provider --cluster <cluster-name> --approve

aws iam list-open-id-connect-providers | grep <alpha-numeric-string-from-last-part-of-above-command> --> output should now be the ARN of the OIDC provider

curl -o iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy --policy-document file://iam-policy.json --> copy ARN

eksctl create iamserviceaccount --region us-east-1 --cluster=<cluster-name> --namespace=kube-system --name=aws-load-balancer-controller --attach-policy-arn=<policy-arn-from-previous-command> --override-existing-serviceaccounts --approve

kubectl apply --validate=false -f https://github.com/jetstack/cert-manager/releases/download/v1.13.2/cert-manager.yaml --> check GitHub for latest release and replace version in link as needed

curl -Lo ingress-controller.yaml https://github.com/kubernetes-sigs/aws-load-balancer-controller/releases/download/v2.6.2/v2_6_2_full.yaml --> check GitHub for latest release and replace version in link as needed

kubectl apply -f ingress-controller.yaml --> Modify according to the video
```
## Not sure why I could not use the latest version of the AWS load balancer controller SIG. Used version 2.4.1 from the tutorial instead for the ingress-controller.yaml
Got an error about the alb ingressclass not being found:
Error from server (invalid ingress class: IngressClass.networking.k8s.io "alb" not found): error when creating "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.6.2/docs/examples/2048/2048_full.yaml": admission webhook "vingress.elbv2.k8s.aws" denied the request: invalid ingress class: IngressClass.networking.k8s.io "alb" not found
[cloudshell-user@ip-10-132-39-177 ~]$ kubectl get ingressclass
No resources found

## Get ingress details from a specific namespace
`kubectl get ingress/ingress-2048 -n game-2048`

## Get ingress details from all namespaces
`kubectl get ingress`

## Explanation of how to use cluster-admin privileges in EKS RBAC
https://chat.openai.com/share/060a6a20-79c4-4f18-ba07-ee3ff6664160

## Using a service and ingress
https://cloud.google.com/kubernetes-engine/docs/tutorials/configuring-domain-name-static-ip?_ga=2.145338164.-1687914125.1702268716

## Using certs with service and ingress
Can take up to an hour for the certificate to be provisioned and associated with the load balancer.
https://cloud.google.com/kubernetes-engine/docs/how-to/managed-certs

## Deploy a load balancer with a cert
Cert provisioning seems far more convoluted in GCP than in AWS. Two different kinds of Certificates in the console.
One is for the new Certificate Manager, which requires certs to be authenticated somehow? No button to do it for us.
The other is classic certificates, which are provisioned by Classic Load Balancing in GCP.
https://cloud.google.com/certificate-manager/docs/deploy-google-managed-lb-auth#wait_until_the_certificate_has_been_activated


############################

# Completed
- Set up load balancer manually and route requests to the Amazon Linux instance running the app
- Package up flask app (or whatever it will be) into a Docker image
  - Ended up using tasky, but was able to build flask app into Docker image too
- Deploy Docker image on EKS
- Integrate EKS with ALB ingress-controller, certs, and HTTP --> HTTPS redirects
- Set up certificate and associate with ALB
- Configure automatic EBS snapshots with replication to S3 buckets (will do `mongodump` instead)
- Test restoring from snapshots by adding an additional DB after a snapshot was taken (used `mongorestore`)
- Get all of this stuff into Terraform
- Do some better scripting of the backups to write output of the commands to logs
  - Just encapsulated the existing script and then run a shell_redirector.sh script to redict stderr and stdout to a log
- Need to get Docker credentials in Parameter Store into Terraform
- Append an ENI or some other static IP or hostname to the mongodb EC2 in case of instance failure
- Set up authentication on mongodb
- Fix the issue with the .env file not being dynamically created by the build. Fine for dev, not okay for production. Should use env vars and parameter store.
- Need to find a more secure way of passing auth information to the EC2 instance for the mongodb backup scripts
  - Do not like having password in plaintext sitting there. Maybe some kind of separate script that pulls an env var from parameter store or secrets manager with the instance creds?
  - Needed to use "" instead of '' and escape the $ in the awk command since this is being echoed out with single quote
  ```
  password=$(aws ssm get-parameter --name mongodb_password --with-decryption --output text | awk "{print \$7}")

  mongosh --password "$password"
  ```
- Consider adding nginx for additional web app security protections like XSS and CSP
- Consider associating a WAF with basic AWS managed rules
- Run tfsec and pre-commit on this build repo

# To-Do:
- Remediate the one critical finding from the tfsec scans of my cluster being publicly accessible from any IP address
  - https://aquasecurity.github.io/tfsec/v1.28.4/checks/aws/eks/no-public-cluster-access-to-cidr/
  - Probably need to have build jobs deployed in VPC and then also allow list my computer's IP (tough when switching locations)
- Finish reviewing remaining pre-commit findings:
  - https://us-east-1.console.aws.amazon.com/codesuite/codebuild/341320276178/projects/wiz-dev-infra/build/wiz-dev-infra%3A2479dbb5-19a2-41f9-aa9d-14d3a1fea055/?region=us-east-1
- Figure out how to lock down mongodb to just the vpc cidr. 
  - It did not like the /20 at the end, so went with 0.0.0.0 instead
- Maybe try figuring out why the flask apps just do not run
- Update the wiz-dev-infra terraform with the IAM service account, role, and OIDC provider created from the ALB ingress controller
- Figure out if there is some sort of janky way to get the DNS name of the EKS-owned ALB so it can be populated into the A record
  - Does not appear to be so, at least not using Terraform data source. This appears to be a common manual process/problem
  - Could try using the aws cli if I can store output from a null resource local-exec provisioner
- Could do a static private IP address using a primary network interface resource, but will do that later. Opting for EIP instead
  - ENI seems to break connection between application and database, so removing that and will figure out a hostname or something else to associate with the database. Or make sure it always has the same private IP using an association
  - Could also do it on the app side where I use an `ec2 describe` command to get the private IP of the instance named `wiz-dev-mongo` and then populate that into the `mongodb_uri`
- Logging, Logging, Logging. Should enable CloudTrail and better understand how to get apps from containers into CloudWatch
- Figure out a better mechanism for bindIp in mongodb than 0.0.0.0
- Learn more about mongodb connection string formats (SRV) and connecting over TLS
  - Documentation: https://www.mongodb.com/docs/manual/reference/connection-string/#std-label-connections-connection-options
- Should have used a standard naming convention and/or tagging when naming SSM parameters to make it easier for specific builds to access
  - Ex: could prefix them all as dev-wiz or something
- Figure out a better way to reference the certificate-arn in the ingress controller section. Do not like hard-coding
  - Maybe I can pass it in as an environment variable when running the kubectl command?
    - That does not seem to work. Back to the drawing board
- Usernames can be sensitive too. Should put that into parameter store as well
- Use the account baseline structure for this module so it can be easily deployed into other AWS accounts (dev/prod)
- Create an AMI of the mongodb instance with everything pre-installed
- More testing around autoscaling under load
- Provision mongodb EC2 in an autoscaling group or set up some kind of health check in case it fails
- Deploy to GCP
- Create service account in GCP
- Apply creds from service account to this repo
- Begin importing existing infra (cluster, Ubuntu VM, GCS Bucket, etc.)
- Run terraform and check for drift
- Fine-grain the permissions on the bucket and VM for writing to GCS buckets
    - Just by enabling read and write to storage on the VM and making bucket public, everything works???
- Finish by associating HTTPS certificate with the ingress
- Also need to do an HTTP to HTTPS redirect
- Look into WAF equivalent of GCP

## Requirements

| Name | Version |
|------|---------|
| google | 5.6.0 |

## Providers

| Name | Version |
|------|---------|
| google | 5.6.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [google_storage_bucket.state](https://registry.terraform.io/providers/hashicorp/google/5.6.0/docs/resources/storage_bucket) | resource |

## Inputs

No inputs.

## Outputs

No outputs.
