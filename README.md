# DevOps Assignment - Step-by-Step Guide

Everything for the 7 tasks is in this folder. **Push the whole folder to a Git repo (repo root = this folder)** - Jenkins, GitHub Actions and Argo CD all read from it.

```
java-app/            Task 1/4/6 sample app (JDK-only HTTP server) + unit tests, functional tests (*FunctionalIT), JMeter plan, Dockerfile
python-app/          Task 2 sample app (Flask) + pytest unit/functional tests, Locust perf test, wheel build, Dockerfile
gitops/              Kustomize manifests + Argo CD Application definitions (one app per source: nexus / jfrog)
jenkins/             Jenkinsfile.java (Task 1), Jenkinsfile.python (Task 2)
scripts/             git-to-s3.sh (Task 3), maven-pipeline.sh (Task 4), sonar-scan.sh (Task 5)
.github/workflows/   maven-ci.yml (Task 6)
terraform/           Task 7 (bootstrap/ for remote state, modules/vpc, security_groups, autoscaling)
```

---------------------------------------------------------------------

## Part 0 - Build the lab (do this once, ~1-2 hours)

The cheapest setup that makes every task work: **one Ubuntu VM (4 vCPU / 8 GB RAM / 40 GB disk)** - a cloud VM, or a local VM. Jenkins, Nexus, SonarQube and a small Kubernetes cluster all live on it. JFrog is SaaS (trial). Replace `VM_IP` below with the VM's IP.

### 0.1 Base tools on the VM
```bash
sudo apt update && sudo apt install -y openjdk-17-jdk maven git curl jq unzip python3-venv python3-pip gettext-base docker.io
sudo usermod -aG docker $USER && newgrp docker

# kubectl, kind (local k8s), argocd CLI
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && sudo install kubectl /usr/local/bin/
curl -Lo kind https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64 && sudo install kind /usr/local/bin/
curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64 && sudo install argocd /usr/local/bin/
```

### 0.2 Nexus Repository (free Community Edition, or Pro trial)
```bash
docker run -d --name nexus --restart unless-stopped -p 8081:8081 -p 8082:8082 -v nexus-data:/nexus-data sonatype/nexus3
docker exec nexus cat /nexus-data/admin.password        # first login: admin / <this>  (wait ~2 min for startup)
```
In the Nexus UI (`http://VM_IP:8081`) -> *Settings (gear) -> Repository -> Repositories -> Create*:
| Type | Name | Notes |
|---|---|---|
| `maven2 (hosted)` | `maven-releases` | Version policy **Release**, deployment policy **Allow redeploy** |
| `pypi (hosted)` | `pypi-hosted` | |
| `docker (hosted)` | `docker-hosted` | **HTTP port = 8082**, tick *Allow anonymous docker pull* = OFF |

Then *Security -> Realms* -> add **Docker Bearer Token Realm** to Active. Create a user `ci` (Security -> Users) with role `nx-admin` (fine for a trial).

### 0.3 SonarQube (free Community Build)
```bash
docker run -d --name sonarqube --restart unless-stopped -p 9000:9000 -v sonar-data:/opt/sonarqube/data sonarqube:community
```
(If that tag is not found, check Docker Hub for the current Community image tag.) Open `http://VM_IP:9000`, log in `admin/admin` and change the password. If it crash-loops on Linux: `sudo sysctl -w vm.max_map_count=524288`.

Create **two tokens** (My Account -> Security -> Generate Tokens):
- `jenkins-token` (type *User token*) - used by Jenkins and GitHub Actions
- `admin-token` (type *User token*) - used only by `scripts/sonar-scan.sh` (Task 5) to mint short-lived tokens

### 0.4 JFrog Cloud trial
1. Sign up at **jfrog.com/start-free** -> you get `YOURTRIAL.jfrog.io`.
2. *Administration -> Repositories -> Create Local Repository*:
   - **Maven** -> key `demo-maven-local`
   - **PyPI** -> key `demo-pypi-local`
   - **Docker** -> key `demo-docker-local`
3. *Administration -> User Management -> Access Tokens* (or "Set Me Up") -> generate an **identity token**. Username = your login email, password = that token.

### 0.5 Let Docker push to Nexus over HTTP (needed because the lab has no TLS)
```bash
echo '{ "insecure-registries": ["VM_IP:8082"] }' | sudo tee /etc/docker/daemon.json
sudo systemctl restart docker && docker restart nexus sonarqube
docker login VM_IP:8082 -u ci          # must say "Login Succeeded"
docker login YOURTRIAL.jfrog.io        # JFrog email + identity token
```

### 0.6 Kubernetes + Argo CD
A local `kind` cluster cannot pull from an HTTP registry without extra config, so use **minikube** (it has a flag for exactly this):
```bash
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64 && sudo install minikube-linux-amd64 /usr/local/bin/minikube
minikube start --driver=docker --cpus=2 --memory=3500 --insecure-registry "VM_IP:8082"

kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server
kubectl -n argocd port-forward --address 0.0.0.0 svc/argocd-server 8443:443 &      # UI: https://VM_IP:8443
```
Log in and create an API token for Jenkins:
```bash
PW=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
argocd login localhost:8443 --username admin --password "$PW" --insecure

kubectl -n argocd patch cm argocd-cm --type merge -p '{"data":{"accounts.jenkins":"apiKey"}}'
kubectl -n argocd patch cm argocd-rbac-cm --type merge -p '{"data":{"policy.csv":"p, jenkins, applications, *, */*, allow"}}'
argocd account generate-token --account jenkins      # <- save this: Jenkins credential "argocd-token"
```

### 0.7 Jenkins
```bash
docker run -d --name jenkins --restart unless-stopped -p 8080:8080 -p 50000:50000 \
  -v jenkins_home:/var/jenkins_home jenkins/jenkins:lts-jdk17
```
> The pipelines call `mvn`, `docker`, `python3` and `argocd` on the *agent*, so the simplest route is to install Jenkins **directly on the VM** (https://www.jenkins.io/doc/book/installing/linux/), then `sudo usermod -aG docker jenkins && sudo systemctl restart jenkins`. If you keep Jenkins in a container instead, you must add those tools to it.

Unlock Jenkins, install suggested plugins **plus**: *SonarQube Scanner, Workspace Cleanup, Pipeline: Stage View, Timestamper, JUnit*.

**Manage Jenkins -> Credentials -> (global) -> Add** (IDs must match exactly):
| ID | Kind | Value |
|---|---|---|
| `nexus-creds` | Username with password | Nexus `ci` user |
| `jfrog-creds` | Username with password | JFrog email + identity token |
| `argocd-token` | Secret text | token from 0.6 |
| `sonar-token` | Secret text | `jenkins-token` from 0.3 |

**Manage Jenkins -> System -> SonarQube servers -> Add**: Name **`sonarqube`**, URL `http://VM_IP:9000`, token = `sonar-token`.
**Manage Jenkins -> Tools -> SonarQube Scanner -> Add**: Name **`sonar-scanner`** (install automatically) - only the Python pipeline needs this.
In SonarQube: *Administration -> Configuration -> Webhooks -> Create*: URL `http://VM_IP:8080/sonarqube-webhook/` (this is what lets `waitForQualityGate` return).

### 0.8 Wire Argo CD to the repo (one-time)
```bash
# 1. edit repoURL in gitops/argocd/*.yaml to YOUR repo (a public repo is the easiest)
# 2. namespaces + registry pull secrets (the cluster needs credentials to pull private images)
for app in java-app python-app; do for src in nexus jfrog; do kubectl create namespace $app-$src; done; done
for app in java-app python-app; do
  kubectl -n $app-nexus create secret docker-registry regcred-nexus --docker-server=VM_IP:8082 --docker-username=ci --docker-password='NEXUS_PASSWORD'
  kubectl -n $app-jfrog create secret docker-registry regcred-jfrog --docker-server=YOURTRIAL.jfrog.io --docker-username='you@email' --docker-password='JFROG_TOKEN'
done
# 3. register the 4 Argo applications
kubectl apply -f gitops/argocd/
```
They show up as *OutOfSync/Degraded* until the first pipeline run supplies a real image. That is expected.

---------------------------------------------------------------------

## Task 1 - Jenkins pipeline: Maven

**What it does:** `jenkins/Jenkinsfile.java` -> build -> unit tests -> functional tests -> JMeter perf test -> Sonar scan + quality gate -> docker build -> *(in parallel)* push jar+image to Nexus and to JFrog -> *(in parallel)* Argo CD deploys the Nexus image and the JFrog image.

**Steps**
1. Open `jenkins/Jenkinsfile.java` and edit the `environment { }` block: `NEXUS_HOST`, `YOURTRIAL`, `ARGOCD_HOST:PORT`. Commit + push.
2. Jenkins -> **New Item** -> name `maven-pipeline` -> **Pipeline** -> *Definition: Pipeline script from SCM* -> Git -> your repo URL -> branch `main` -> **Script Path: `jenkins/Jenkinsfile.java`** -> Save.
3. **Build Now**. Watch *Stage View*.
4. Verify:
   - Nexus -> Browse -> `maven-releases` has `com/example/demo-app/1.0.N/`, and `docker-hosted` has `demo-app`
   - JFrog -> Application -> Artifactory -> Artifacts shows the same
   - Argo CD UI: `java-app-nexus` and `java-app-jfrog` are **Healthy / Synced**
   - `kubectl -n java-app-nexus get pods` -> 2 Running; `kubectl -n java-app-nexus port-forward svc/java-app 9090:80` then `curl localhost:9090/health`

**How the Argo CD step works:** `argocd app set --kustomize-image` tells Argo CD "deploy *this* image from *this* registry" for the application, then `sync` + `wait --health`. The two applications deploy to separate namespaces, so you can prove each registry independently.

## Task 2 - Jenkins pipeline: Python

Same shape; differences: builds a **wheel** (`python -m build --wheel`), tests with pytest, load-tests with Locust, scans with `sonar-scanner`, pushes the wheel with `twine` to Nexus/JFrog PyPI repos, and the Docker image installs that same wheel.
1. Edit the `environment { }` block in `jenkins/Jenkinsfile.python`.
2. New Item `python-pipeline` -> Pipeline from SCM -> **Script Path: `jenkins/Jenkinsfile.python`**.
3. Build; verify the wheel in Nexus `pypi-hosted` / JFrog `demo-pypi-local` and Argo apps `python-app-nexus` / `python-app-jfrog`.

## Task 3 - Shell script: clone repo -> upload to S3

```bash
aws configure                      # IAM user with s3:ListBucket, s3:PutObject, s3:GetObject on the bucket
aws s3 mb s3://my-unique-bucket-name --region ap-south-1

./scripts/git-to-s3.sh https://github.com/octocat/Hello-World.git my-unique-bucket-name backups/hello main
# private repo:  GIT_TOKEN=ghp_xxx ./scripts/git-to-s3.sh https://github.com/me/private.git my-bucket
# also upload .git: INCLUDE_GIT=1 ...    mirror deletions: DELETE=1 ...
```
It checks AWS credentials and the bucket first, shallow-clones into a temp dir (deleted on exit, even on failure), `aws s3 sync`s everything except `.git`, then prints the object count.

## Task 4 - Shell script: Maven -> Nexus/JFrog -> kubectl

```bash
cp scripts/config.env.example scripts/config.env && nano scripts/config.env     # fill in URLs/credentials
./scripts/maven-pipeline.sh                      # all stages
./scripts/maven-pipeline.sh build unit docker    # or just some stages
```
Stages: `build unit functional perf sonar docker push-nexus push-jfrog deploy-nexus deploy-jfrog`.
The deploy stages create a namespace + registry pull secret, render `scripts/k8s/app.yaml.tpl` with the exact image from each registry (`envsubst`), `kubectl apply` it, and wait for `rollout status`. `kubectl get pods -n demo-nexus -n demo-jfrog` to verify. The sonar stage calls Task 5's script.

## Task 5 - Sonar scan with a dynamic, single-project, 24h token

```bash
export SONAR_HOST_URL=http://VM_IP:9000
export SONAR_ADMIN_TOKEN=<admin-token from 0.3>
export SONAR_PROJECT_KEY=demo-app
./scripts/sonar-scan.sh java-app
```
What happens, in order:
1. `POST /api/user_tokens/generate` with **`type=PROJECT_ANALYSIS_TOKEN`** + `projectKey=demo-app` -> the token can run analysis on *that one project only*.
2. `expirationDate=<tomorrow, UTC>` -> expires within 24h.
3. The scan runs with the new token passed as the `SONAR_TOKEN` env var (not on the command line, so it isn't visible in `ps`).
4. A `trap` **revokes** the token when the script ends - the 24h expiry is the safety net if the script is killed.

Good to know for the interview: SonarQube expiry is a *calendar date*, not an hour count, so "24 hours" is implemented as "tomorrow's date"; revoking after the scan is what makes the real lifetime minutes. The user behind `SONAR_ADMIN_TOKEN` needs the *Execute Analysis* permission on the project, plus *Create Projects* if you want auto-creation. Check afterwards in SonarQube -> My Account -> Security: the token is gone (revoked).

## Task 6 - GitHub Actions

1. Push the repo to GitHub.
2. Repo -> *Settings -> Secrets and variables -> Actions*:
   - **Secrets:** `SONAR_TOKEN`, `NEXUS_USER`, `NEXUS_PASSWORD`, `JFROG_USER`, `JFROG_PASSWORD`
   - **Variables:** `SONAR_HOST_URL`, `NEXUS_MAVEN_URL`, `NEXUS_DOCKER_HOST`, `JFROG_HOST`, `JFROG_MAVEN_URL`, `JFROG_DOCKER_REPO`
3. **Important - network reachability:** GitHub-hosted runners can't reach `http://VM_IP:...` on a private VM. Either (a) install a **self-hosted runner** on the lab VM (*Settings -> Actions -> Runners -> New self-hosted runner*, follow the commands shown) and add variable `RUNNER_LABEL=self-hosted`, or (b) use publicly reachable Nexus/Sonar. For (a) the VM's Docker already trusts the Nexus HTTP registry from step 0.5.
4. Push to `main` (or *Actions -> maven-ci -> Run workflow*). Two jobs run: `build-and-test` (build, unit, functional, JMeter, Sonar) then `docker-and-publish` (docker build, push to Nexus and JFrog). Publishing is skipped on pull requests.

## Task 7 - Terraform on AWS

**Prereqs:** Terraform >= 1.5, AWS CLI configured (`aws configure`), an IAM user/role that can create VPC/EC2/ELB/ASG/S3/DynamoDB. Region defaults to `ap-south-1` (Mumbai).

**Step 1 - create the remote-state bucket + lock table (once)**
```bash
cd terraform/bootstrap
terraform init && terraform apply
terraform output -raw backend_hcl > ../backend.hcl
```
**Step 2 - deploy dev**
```bash
cd ..
curl -s https://checkip.amazonaws.com             # your public IP -> put it in environments/dev.tfvars as "x.x.x.x/32"
terraform init -backend-config=backend.hcl -backend-config="key=web/dev/terraform.tfstate"
terraform plan  -var-file=environments/dev.tfvars
terraform apply -var-file=environments/dev.tfvars
```
Takes ~5 minutes. Then:
```bash
terraform output load_balancer_dns_name           # open http://<that> - refresh: the page shows different instances
terraform output instance_type                    # t2.micro
```
**Step 3 - prove the env switch:** use a separate state key so dev is untouched:
```bash
terraform init -reconfigure -backend-config=backend.hcl -backend-config="key=web/prod/terraform.tfstate"
terraform apply -var-file=environments/prod.tfvars     # instance_type output = t3.medium
```
(or, for a quick check only: `terraform plan -var environment=prod -var ssh_cidr=1.2.3.4/32` or `TF_VAR_environment=prod`.)

**Step 4 - clean up (ALB + instances cost money):** `terraform destroy -var-file=environments/<env>.tfvars`. Leave `bootstrap/` alone until everything else is destroyed.

**How each requirement is met**
| Requirement | Where |
|---|---|
| VPC, subnets in 2 AZs | `modules/vpc` - 2 public subnets, AZs taken from `aws_availability_zones` |
| 2 EC2 in an ASG behind a load balancer | `modules/autoscaling` - launch template, ASG (min/desired 2), ALB, target group, listener |
| SG: HTTP from internet to LB; SSH only from a CIDR | `modules/security_groups` - web SG allows port 80 only *from the ALB's SG*, port 22 only from `ssh_cidr` (validation rejects `0.0.0.0/0`) |
| Modules for VPC / ASG / SG | `terraform/modules/*` |
| NGINX via provisioner | `terraform_data.install_nginx` (`remote-exec`) in the autoscaling module |
| Remote state S3 + DynamoDB lock | `bootstrap/` creates them (versioned, encrypted, private, TLS-only); `versions.tf` has `backend "s3" {}` |
| AMI via data source | `data "aws_ami" "al2023"` in `main.tf` |
| dev -> t2.micro, prod -> t3.medium | `local.instance_type = var.environment == "prod" ? "t3.medium" : "t2.micro"` |
| Output LB DNS | `load_balancer_dns_name` in `outputs.tf` |

**Design decision you should be ready to explain:** Terraform provisioners only attach to resources Terraform creates, but ASG instances are created by AWS. So the module (1) waits for the ASG, (2) looks up the running instances with `aws_instances`, and (3) runs `remote-exec` against each one (one `terraform_data` per desired instance; it re-runs if an instance IP changes). The launch template's `user_data` *also* installs NGINX, so instances that the ASG launches later (scale-out or replacement) are healthy without Terraform's help, and the ALB health check can pass during the first apply. The provisioner is therefore idempotent verification plus the page customization. This also means the machine running `terraform apply` must be inside `ssh_cidr` (instances get public IPs for this reason).

**Notes:** the SSH key is generated by Terraform (`tls_private_key`) and therefore sits in the encrypted state file - fine for an assignment, not for production (use SSM Session Manager). The S3 backend's `dynamodb_table` locking is deprecated in newer Terraform in favour of S3-native locking (`use_lockfile = true`) but is still supported; the assignment asks for DynamoDB so that is what is used.

---------------------------------------------------------------------

## Troubleshooting
| Symptom | Fix |
|---|---|
| `docker push` -> "http: server gave HTTP response to HTTPS client" | step 0.5 (insecure-registries) on the machine running Docker |
| Nexus docker login 401 | enable *Docker Bearer Token Realm* (0.2) |
| Pod `ImagePullBackOff` | pull secret missing/wrong (0.8), or minikube not started with `--insecure-registry` |
| Pipeline hangs at *Quality Gate* | Sonar webhook missing (0.7) |
| `mvn deploy` -> 400 "does not allow updating assets" | Nexus `maven-releases` -> *Allow redeploy* (the pipelines already use a unique version per build) |
| `argocd` -> "x509: certificate signed by unknown authority" | pipelines already pass `--insecure`; check `ARGOCD_SERVER` is `host:port` without `https://` |
| Terraform provisioner timeout | `ssh_cidr` doesn't contain the IP you are running Terraform from |
| Sonar Task 5: 403 on token generate | the `admin-token` user lacks *Execute Analysis* on the project |

## What was and wasn't tested while preparing this
Verified here: Python app (unit + functional tests pass, wheel builds); Java app compiles and its four endpoints respond correctly; `git-to-s3.sh` logic against a stubbed `aws` CLI; `sonar-scan.sh` request flow (project create -> scoped token -> scan -> revoke) against a mock SonarQube; all YAML/XML parse; all shell scripts pass `bash -n`; all Terraform files parse as valid HCL.
**Not** run here (no access in my sandbox): Maven itself (Maven Central was blocked), Jenkins, Nexus, JFrog, Argo CD, Kubernetes, real AWS, and `terraform validate/plan`. Expect to fix small environment-specific things (URLs, versions, plugin names) on first run - run each stage once by hand before demoing.
