# By Cesar Armengol, June 3rd 2025

This repository (main.tf) holds the exercise for Palo Altoas describe here:

Infrastructure deployment task:

Create the Terraform deployment to host a stateless application containerised here:
https://hub.docker.com/r/nginxdemos/hello/

Create the architecture diagram for the deployment using:
https://github.com/mingrammer/diagrams

 
If applicable depends on your chosen approach:

	1. Ensure application is deployed behind a load balancer.

	2. On the point of the load balancer the application needs to be HA.

	3. Ensure that the network hosting of the web application is secured.

	4. If application is hosted in a VM build as well the infrastructure for safely access It via ssh

	5. Make use of service accounts where applicable.

	6. Depending on how your application is hosted, propose options for securing access to the web application itself.

Create all the public/private networks needed to secure unwanted access from the Internet to the infrastructure hosting the web application.![image](https://github.com/user-attachments/assets/cd4922e6-af36-4a39-826e-ddf340402cd3)


The code follows the above indications and deploys several resources on AWS, namely:

	- One Application Load Balancer (ALB) that receives inbound connections on port 80. This ALB sits on 2 Public Subnets for High Availability purposes.
	  There is a Security Group associated with this ALB that only allows traffic on Port 80. (points 1,2 & 3)

 	- The "nginxdemo/hello" container pulled from a public repo is placed on the AWS Fargate service and is located on 2 private subnets for High Availability purposes. It accepts inbound connections from the ALB. 
	- 2 NAT Gateways, each associated with one public subnet for HA. 

 - The code can be deployed via:
   $  terraform init
   $  terraform plan
   $  terraform apply 





