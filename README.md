> Ce dépôt regroupe trois TP : **TP13** (Floci, Terraform, OpenTofu), **TP14** (K3s et Kubernetes, voir [TP14](#tp14--kubernetes-avec-k3s)) et **TP15** (Helm et Kustomize, voir [TP15](#tp15--packager-une-application-kubernetes-avec-helm-et-kustomize)).

# TP13 : Cloud AWS local avec Floci et Terraform avancé

**Environnement :** VM Ubuntu Server, Docker, Terraform v1.17.2, OpenTofu v1.13.9, provider `hashicorp/aws` v6.73.0, Node.js 24, AWS CLI v2

Ce TP utilise **Floci**, un émulateur AWS local (licence MIT) exposé sur `http://localhost:4566`. Aucun compte AWS, aucune carte bancaire et aucune facture ne sont nécessaires : les identifiants sont fictifs (`test` / `test`, compte simulé `000000000000`).

---

## Sommaire

1. [Structure du rendu](#1-structure-du-rendu)
2. [Démarrage de Floci](#2-démarrage-de-floci)
3. [Partie 1 : AWS CLI](#3-partie-1--aws-cli-contre-floci)
4. [Partie 2 : SDK JavaScript](#4-partie-2--sdk-javascript)
5. [Partie 3 : Terraform et provider AWS](#5-partie-3--terraform-avec-le-provider-aws)
6. [Partie 4 : modules, environnements, state distant](#6-partie-4--modules-environnements-et-state-distant)
7. [Partie 5 : scan IaC et OpenTofu](#7-partie-5--scan-iac-et-opentofu)
8. [Comparaisons](#8-comparaisons)
9. [Difficultés rencontrées](#9-difficultés-rencontrées)
10. [Nettoyage](#10-nettoyage)
11. [Liste des captures](#11-liste-des-captures)

---

## 1. Structure du rendu

```
rendu-tp13/
├── README.md
├── captures/
│   ├── floci-cli.png
│   ├── sdk-demo.png
│   ├── terraform-apply.png
│   ├── drift.png
│   ├── remote-state.png
│   ├── state-lock.png
│   ├── iac-scan.png
│   └── opentofu.png
├── main.tf
├── providers.tf
├── variables.tf
├── outputs.tf
├── backend.tf
├── dev.tfvars
├── staging.tfvars
├── prod.tfvars
├── .trivyignore
├── .terraform.lock.hcl
└── modules/
    └── secure-bucket/
        ├── main.tf
        ├── variables.tf
        └── outputs.tf
```

Le fichier `terraform.tfstate`, le dossier `.terraform/` et les plans (`tfplan`) ne sont pas fournis.

---

## 2. Démarrage de Floci

```bash
docker run -d --name floci -p 4566:4566 \
  -v /var/run/docker.sock:/var/run/docker.sock floci/floci
docker logs floci
```

Le socket Docker est monté parce que Lambda exécute les fonctions dans des conteneurs. Le conteneur passe à l'état `healthy`.

---

## 3. Partie 1 : AWS CLI contre Floci

Un profil dédié contient des identifiants fictifs et l'endpoint local :

```bash
aws configure set aws_access_key_id test --profile floci
aws configure set aws_secret_access_key test --profile floci
aws configure set region us-east-1 --profile floci
aws configure set endpoint_url http://localhost:4566 --profile floci
export AWS_PROFILE=floci
aws sts get-caller-identity
```

Résultat : `Account = 000000000000`, `Arn = arn:aws:iam::000000000000:root`.

Services manipulés :

| Service | Opérations réalisées |
|---|---|
| S3 | création du bucket `tp13-demo`, envoi, listage et lecture de `hello.txt` |
| SQS | création de la file `tp13-demo`, `send-message`, `receive-message` |
| DynamoDB | table `visits` (clé `id` de type S, `PAY_PER_REQUEST`), `put-item` et `scan` |
| Secrets Manager | secret `tp13/demo/api-key`, `get-secret-value` |
| Lambda | fonction `hello` (`nodejs22.x`), `lambda invoke`, résultat dans `out.json` |

![Commandes AWS CLI réussies](captures/floci-cli.png)

La capture regroupe S3 (`hello.txt`, 14 octets), SQS (`ApproximateNumberOfMessages = 1`), DynamoDB (`Count: 2`), `lambda invoke` (`StatusCode: 200`) et Secrets Manager. Sur la dernière commande, l'erreur `ResourceExistsException` indique simplement que le secret avait déjà été créé : `get-secret-value` relit bien `ma-cle-demo`.

> Avec `endpoint_url` dans le profil, l'option `--endpoint-url` est inutile. Il faut toujours vérifier le profil actif avant une commande destructive : sur un vrai compte AWS, la même commande aurait des effets réels.

---

## 4. Partie 2 : SDK JavaScript

```bash
cd sdk-demo && npm install && npm start
QUEUE_URL=$QURL npm start
```

Le programme écrit et liste des objets dans `tp13-demo`, puis envoie un message JSON dans la file SQS (TODO complété). Le message est relu avec `aws sqs receive-message`.

![Programme SDK](captures/sdk-demo.png)

Le premier `npm start` liste `hello.txt` et affiche `QUEUE_URL manquant` (variable absente). Avec `QUEUE_URL=$QURL`, le programme envoie le message `{ event: 'contact.created', ... }` (MessageId affiché). `aws sqs receive-message` relit un message de la file : une file standard ne garantit pas l'ordre, donc c'est ici le premier message `{"event":"test"}` de la partie 1 qui est renvoyé.

**Question : quelle valeur prend `AWS_ENDPOINT_URL` dans le réseau Compose ?**
Dans Compose, `localhost` désigne le conteneur du programme lui-même, pas Floci. L'endpoint doit donc utiliser le nom du service Compose : `http://floci:4566` (si le service s'appelle `floci`).

---

## 5. Partie 3 : Terraform avec le provider AWS

### 5.1 Explication de `providers.tf`

| Élément | Rôle |
|---|---|
| `access_key` / `secret_key = "test"` | Identifiants fictifs, acceptés sans vérification par Floci. |
| `skip_credentials_validation` | Terraform ne vérifie pas les identifiants auprès du vrai STS d'AWS. |
| `skip_requesting_account_id` | Terraform ne demande pas l'ID de compte à AWS (appel externe inutile). |
| `skip_metadata_api_check` | Terraform ne contacte pas l'API de métadonnées EC2 (169.254.169.254), absente ici et source de timeout. |
| `s3_use_path_style = true` | URL de la forme `localhost:4566/<bucket>` au lieu de `<bucket>.localhost:4566`, dont le sous-domaine ne se résout pas en local. |
| `endpoints { ... }` | Redirige chaque service (S3, SQS, DynamoDB, Secrets Manager, Lambda, IAM, STS) vers Floci. Sans ce bloc, Terraform appellerait le vrai AWS. |
| `default_tags` | Ajoute automatiquement `project`, `environment` et `managed-by` à toutes les ressources. |

`required_version = ">= 1.10"` est exigé car le verrou natif `use_lockfile` n'existe que depuis Terraform 1.10.

### 5.2 Ressources créées (`main.tf`)

- **S3** : bucket versionné, accès public bloqué (4 options à `true`), chiffrement AES256.
- **SQS** : file `tp13-contact-<env>` avec file de lettres mortes (`maxReceiveCount = 3`) et `sqs_managed_sse_enabled = true`.
- **DynamoDB** : table `tp13-visits-<env>` (`PAY_PER_REQUEST`, clé `id` de type S).
- **Secrets Manager** : secret `tp13/<env>/api-key`, valeur fournie par la variable `api_key` marquée `sensitive = true` et passée par `TF_VAR_api_key` (jamais écrite dans le code).

### 5.3 Cycle complet

```bash
terraform init && terraform fmt && terraform validate
terraform plan -out tfplan
terraform apply tfplan
terraform output
```

Résultat : `Apply complete! Resources: 9 added, 0 changed, 0 destroyed.`
Dans le plan, la valeur du secret apparaît comme `(sensitive value)`.

Vérifications avec AWS CLI :

```bash
aws s3api get-bucket-versioning --bucket tp13-uploads-dev        # Enabled
aws s3api get-public-access-block --bucket tp13-uploads-dev      # 4 x true
aws s3api get-bucket-encryption --bucket tp13-uploads-dev        # AES256
aws sqs list-queues && aws dynamodb list-tables
aws secretsmanager get-secret-value --secret-id tp13/dev/api-key
```

![terraform apply et vérifications](captures/terraform-apply.png)

### 5.4 Dérive (drift)

La table `tp13-visits-dev` est supprimée à la main avec AWS CLI, puis `terraform plan` est relancé.

**Réaction de Terraform :** il rafraîchit son state (*refresh*), constate que la table présente dans le state n'existe plus dans la réalité, et planifie sa **recréation** (`Plan: 1 to add, 0 to change, 0 to destroy`). Il ne modifie rien sans confirmation. Après `terraform apply`, la table est recréée (vide : Terraform restaure la structure, pas les données), puis `plan` affiche `No changes`.

![Dérive détectée par terraform plan (début)](captures/drift.png)

![Dérive détectée par terraform plan (fin : Plan: 1 to add)](captures/drift-2.png)

Réparation de la dérive (`terraform apply`, réponse `yes`), puis retour à un état propre :

![Réparation : Apply complete, 1 added](captures/drift-reparation.png)

![Après réparation : No changes](captures/drift-no-changes.png)

---

## 6. Partie 4 : modules, environnements et state distant

### 6.1 Notions

| Notion | Explication |
|---|---|
| State | Fichier JSON qui associe chaque ressource du code à un objet réel. Sans lui, Terraform ne sait plus ce qu'il gère. |
| Backend distant | Stocke le state hors du poste (ici S3) pour le partager en équipe et le sauvegarder. |
| Verrou | Empêche deux `apply` simultanés de corrompre le state. |
| Données sensibles | Le state contient des valeurs en clair (secrets) : il faut le chiffrer et restreindre son accès. |

### 6.2 Module `modules/secure-bucket`

Le bucket sécurisé (bucket, versioning, blocage d'accès public, chiffrement) est factorisé dans un module (`var.name`, `var.tags`, sorties `bucket` et `arn`), puis appelé deux fois :

```hcl
module "uploads" {
  source = "./modules/secure-bucket"
  name   = "tp13-uploads-${var.environment}"
}

module "backups" {
  source = "./modules/secure-bucket"
  name   = "tp13-backups-${var.environment}"
}
```

Quatre blocs `moved` déplacent dans le state les ressources existantes (`aws_s3_bucket.uploads` vers `module.uploads.aws_s3_bucket.this`, etc.). Le plan a affiché 4 lignes `has moved to ...` et `Plan: 4 to add, 0 to change, 0 to destroy` (les 4 ressources du nouveau bucket `backups`) : **aucune ressource existante n'a été détruite**.

### 6.3 Validation et fichiers `tfvars`

```hcl
variable "environment" {
  type    = string
  default = "dev"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment doit valoir dev, staging ou prod."
  }
}
```

Fichiers `dev.tfvars`, `staging.tfvars` et `prod.tfvars` (sans secret). Le test `terraform plan -var="environment=test"` est refusé avec le message d'erreur de validation.

![Validation de var.environment](captures/validation-environment.png)

### 6.4 Backend S3 verrouillé

Bootstrap du bucket de state avec AWS CLI (il ne peut pas être créé par le projet qui l'utilise) :

```bash
aws s3 mb s3://tp13-tfstate
aws s3api put-bucket-versioning --bucket tp13-tfstate \
  --versioning-configuration Status=Enabled
```

`backend.tf` : bucket `tp13-tfstate`, clé `envs/dev/terraform.tfstate`, endpoint Floci, `use_path_style`, options `skip_*` et `use_lockfile = true`. Un backend ne peut pas utiliser de variables, donc tout y est écrit en dur.

Migration :

```bash
terraform init -migrate-state
aws s3 ls s3://tp13-tfstate/envs/
```

Résultat : `envs/dev/terraform.tfstate` et `envs/prod/terraform.tfstate` sont présents dans S3, et `terraform plan` affiche `No changes`.

![State distant dans S3](captures/remote-state.png)

### 6.5 Test du verrou

Terminal 1 : `terraform apply -replace=aws_dynamodb_table.visits` laissé en attente à `Enter a value:`.
Terminal 2 : `terraform plan` échoue.

Terminal 1 : l'`apply` est laissé en attente de confirmation, ce qui garde le verrou.

![Terminal 1 : apply en attente (Enter a value)](captures/state-lock-terminal1.png)

Terminal 2 : le `plan` est bloqué par le verrou.

![Erreur Error acquiring the state lock](captures/state-lock.png)

L'erreur affiche `Error acquiring the state lock`, avec `PutObject ... StatusCode: 412 ... PreconditionFailed` et les informations du verrou (ID, chemin, opération `OperationTypeApply`, utilisateur). Cela prouve que **Floci gère les écritures conditionnelles S3** : le verrou natif `use_lockfile` fonctionne, donc **aucune bascule vers `dynamodb_table` n'a été nécessaire**.

### 6.6 Séparation des environnements

Une clé de state distincte par environnement, choisie à l'initialisation :

```bash
terraform init -backend-config="key=envs/prod/terraform.tfstate" -reconfigure
terraform plan -var-file=prod.tfvars     # Plan: 13 to add (state vide)
terraform apply -var-file=prod.tfvars
terraform init -backend-config="key=envs/dev/terraform.tfstate" -reconfigure
terraform plan -var-file=dev.tfvars      # No changes
```

**Comparaison des deux approches :**

| | Clé de state par environnement | Workspaces |
|---|---|---|
| Principe | Un fichier de state distinct, choisi à l'`init` | Plusieurs states dans le même backend, `terraform workspace select` |
| Visibilité | Explicite : le chemin indique l'environnement | Implicite : facile d'oublier dans quel workspace on se trouve |
| Risque | Oublier `-reconfigure` | Appliquer `prod` en étant resté sur `dev` |
| Isolation | Forte (backends ou droits différents possibles) | Faible (même backend, mêmes droits) |

Pour la production, la clé par environnement (ou des dossiers séparés) est préférable.

---

## 7. Partie 5 : scan IaC et OpenTofu

### 7.1 Checkov et Trivy

```bash
docker run --rm -v "$PWD:/tf" bridgecrew/checkov -d /tf --quiet
docker run --rm -v "$PWD:/tf" aquasec/trivy:latest config /tf
```

**Mauvaise configuration introduite** (sur une copie `terraform-bad`) : `block_public_acls = false`, `block_public_policy = false` et suppression du bloc de chiffrement S3.

Résultats :
- **Checkov** : `Passed checks: 20, Failed checks: 22`. Les échecs liés aux modifications : `CKV_AWS_53` (block public ACLs), `CKV_AWS_54` (block public policy) et `CKV2_AWS_6` (public access block).
- **Trivy** : `AWS-0087 (HIGH): Public access block does not block public policies` sur `modules/secure-bucket/main.tf`, ligne `block_public_policy = false`.

![Scan IaC détectant la mauvaise configuration (AWS-0087, code retour 1)](captures/iac-scan.png)

Code retour du scan bloquant sur le code cassé :

![Code retour = 1 sur terraform-bad](captures/iac-scan-code-retour-casse.png)

Sur le code sain, Checkov restreint aux contrôles d'accès public passe (`Failed checks: 0`, code retour 0) :

![Checkov sur le code sain](captures/iac-checkov-sain.png)

Alerte `AWS-0132` (KMS) de Trivy sur le code sain, acceptée dans `.trivyignore` :

![Trivy AWS-0132 sur le code sain](captures/iac-trivy-sain-aws0132.png)

**Code retour bloquant** (`--exit-code 1 --severity HIGH,CRITICAL`) :

| Code | Code retour |
|---|---|
| Sain (`terraform-starter`) | **0** |
| Cassé (`terraform-bad`) | **1** |

**Exceptions documentées dans `.trivyignore`** (risques acceptés en TP, émulateur local) :

| Identifiant | Raison |
|---|---|
| `AWS-0132` | Chiffrement SSE-S3 (AES256) au lieu d'une clé KMS gérée par le client. |
| `AWS-0096` | Chiffrement SQS géré par le service (`sqs_managed_sse_enabled`) ; cette version de Trivy ne reconnaît que `kms_master_key_id`. |

Les autres échecs Checkov (journalisation S3, réplication inter-régions, rotation des secrets, KMS pour DynamoDB, etc.) existaient déjà sur le code sain : ce sont des exigences de production, acceptées dans le cadre du TP.

**Intégration au pipeline** (Jenkinsfile du TP9) :


Équivalent GitHub Actions (TP10) :

```yaml
iac-scan:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - run: |
        docker run --rm -v "$PWD:/tf" aquasec/trivy:latest config /tf \
          --skip-version-check --ignorefile /tf/.trivyignore \
          --exit-code 1 --severity HIGH,CRITICAL
```

### 7.2 OpenTofu

Le cycle est rejoué sur une copie du projet, avec un state local et l'environnement `staging` (pour ne pas toucher aux states dev et prod) :

```bash
tofu init && tofu plan -var-file=staging.tfvars && tofu apply -var-file=staging.tfvars
```

Résultat : `Apply complete! Resources: 13 added, 0 changed, 0 destroyed.` avec **OpenTofu v1.13.9** et le provider `hashicorp/aws v6.73.0`. Le même code HCL fonctionne sans aucune modification.

![tofu apply réussi](captures/opentofu.png)

![tofu version](captures/opentofu-version.png)

**Comparaison Terraform / OpenTofu :**

| | Terraform | OpenTofu |
|---|---|---|
| Licence | BUSL 1.1 (source disponible, usage concurrent restreint) | MPL 2.0 (open source) |
| Gouvernance | HashiCorp | Linux Foundation, communauté |
| Providers | Registre HashiCorp | Registre OpenTofu, mêmes providers (ici `hashicorp/aws` sans changement) |
| State | JSON | Format compatible |
| Fonction propre | Terraform Cloud / HCP | Chiffrement du state côté client (bloc `encryption`) |

---

## 8. Comparaisons

### Floci, LocalStack et AWS réel

J'ai utilisé Floci pour tout le TP. Voici ce que j'ai constaté, comparé à LocalStack et à AWS réel.

| | Floci | LocalStack Community | AWS réel |
|---|---|---|---|
| Licence | MIT, libre | Jeton d'authentification exigé depuis mars 2026 (d'après l'énoncé, non testé) | Service commercial |
| Services couverts | Ceux du TP : S3, SQS, DynamoDB, Lambda, Secrets Manager, IAM, STS | Catalogue plus large, certains services payants (d'après l'énoncé) | Tous les services |
| Fidélité | Suffisante pour le TP : versioning, chiffrement S3 et verrou S3 conditionnel ont fonctionné. Les files SQS sont lentes (25 à 42 s) | Non testé | Comportement de référence |
| Coût | Gratuit, sans compte ni carte bancaire | Gratuit avec compte et jeton | Facturé à l'usage |
| Usage en CI | Pratique : un seul conteneur et aucun secret à gérer | Possible, mais le jeton doit être stocké comme secret | Coûteux et risqué : comptes dédiés et nettoyage nécessaires |

**Ce que j'en retiens.** Floci m'a permis de tester toute la chaîne (AWS CLI, SDK, Terraform, backend S3 verrouillé, OpenTofu) sans aucun risque de facture. Son principal défaut est la lenteur des files SQS. Je ne l'utiliserais pas pour valider le comportement exact d'un service, car l'émulation ne reproduit pas tout : par exemple, le scanner Trivy exige une clé KMS pour les files SQS, alors que l'émulateur ne gère que le chiffrement par le service. Pour une validation finale avant la production, un vrai compte AWS de test reste nécessaire.
## 9. Difficultés rencontrées

- **Variables d'environnement par terminal** : `AWS_PROFILE` et `TF_VAR_api_key` ne sont pas conservées d'un terminal à l'autre. Dans un nouveau terminal sans `TF_VAR_api_key`, le plan proposait de vider la valeur du secret (`secret_string = (sensitive value) -> null`). L'apply a été refusé. Chaque terminal doit redéfinir ces variables.
- **Pager AWS CLI** : l'option `export AWS_PAGER=""` évite les affichages `...skipping...`.
- **Scan Trivy sain à 1** : le code sain renvoyait 1 à cause de `AWS-0132` (KMS) puis `AWS-0096` (SQS). Ces alertes sont des limites de l'émulateur et de la règle, documentées dans `.trivyignore`.
- **Création lente des files SQS** : environ 25 s à la création et 42 s à la suppression, sans erreur.
- **Plan vide après `sqs_managed_sse_enabled`** : le provider v6 active déjà ce chiffrement par défaut, l'attribut explicite sert surtout à rendre l'intention lisible pour les scanners.

---

## 10. Nettoyage

```bash
tofu destroy -var-file=staging.tfvars                      # state local
terraform init -backend-config="key=envs/prod/terraform.tfstate" -reconfigure
terraform destroy -var-file=prod.tfvars
terraform init -backend-config="key=envs/dev/terraform.tfstate" -reconfigure
terraform destroy -var-file=dev.tfvars
docker rm -f floci
```

Résultat pour dev : `Destroy complete! Resources: 13 destroyed.` Le conteneur `floci` est supprimé en dernier (il efface aussi le bucket `tp13-tfstate`).

---

## 11. Liste des captures

| Fichier | Contenu | Aperçu |
|---|---|---|
| `floci-cli.png` | Commandes S3, SQS, DynamoDB et `lambda invoke` réussies | ![](captures/floci-cli.png) |
| `sdk-demo.png` | Programme SDK : objets listés et message SQS envoyé | ![](captures/sdk-demo.png) |
| `terraform-apply.png` | `terraform apply` puis vérification avec AWS CLI | ![](captures/terraform-apply.png) |
| `drift.png` | `terraform plan` après suppression manuelle de la table | ![](captures/drift.png) |
| `remote-state.png` | State présent dans `s3://tp13-tfstate/envs/` | ![](captures/remote-state.png) |
| `state-lock.png` | Erreur `Error acquiring the state lock` | ![](captures/state-lock.png) |
| `iac-scan.png` | Trivy détectant `AWS-0087` sur le code cassé, code retour 1 | ![](captures/iac-scan.png) |
| `opentofu.png` | `tofu apply` réussi (13 ressources) | ![](captures/opentofu.png) |

### Captures complémentaires

| Fichier | Contenu |
|---|---|
| `drift-2.png`, `drift-reparation.png`, `drift-no-changes.png` | Fin du plan de dérive, réparation, retour à `No changes` |
| `validation-environment.png` | Refus de `environment=test` par la validation |
| `state-lock-terminal1.png` | Terminal 1 : `apply` en attente de confirmation |
| `iac-scan-code-retour-casse.png`, `iac-checkov-sain.png`, `iac-trivy-sain-aws0132.png` | Détails du scan IaC |
| `opentofu-version.png` | `tofu version` : OpenTofu v1.13.9 |

---

# TP14 : Kubernetes avec K3s

**Auteur :** Wissal
**Dates :** 15 au 17 novembre 2026
**Environnement :** Ubuntu Server 26.04, K3s v1.36.5+k3s1 (containerd 2.3.4), kubectl v1.37.2, Ansible core 2.20.1, Vagrant 2.4.9, noyau 7.0.0-43-generic

---

## Sommaire

1. [Choix de l'environnement (plan B)](#1-choix-de-lenvironnement-plan-b)
2. [Structure du rendu](#2-structure-du-rendu)
3. [Partie 1 : cluster K3s avec Ansible](#3-partie-1--cluster-k3s-avec-ansible)
4. [Partie 2 : Pods et Deployments](#4-partie-2--pods-et-deployments)
5. [Partie 3 : Services et Ingress](#5-partie-3--services-et-ingress)
6. [Partie 4 : ConfigMap et Secret](#6-partie-4--configmap-et-secret)
7. [Partie 5 : santé, ressources, déploiements progressifs](#7-partie-5--santé-ressources-et-déploiements-progressifs)
8. [Partie 6 : stockage persistant](#8-partie-6--stockage-persistant)
9. [Partie 7 : HorizontalPodAutoscaler](#9-partie-7--horizontalpodautoscaler)
10. [Défi](#10-défi)
11. [Difficultés rencontrées](#11-difficultés-rencontrées)
12. [Liste des captures](#12-liste-des-captures)

---

## 1. Choix de l'environnement (plan B)

Le sujet prévoit un cluster à deux nœuds créé par Vagrant. Ce n'était pas possible sur ma VM de lab :

| | Ma VM | Requis |
|---|---|---|
| vCPU | 4 | 4 |
| RAM | 4,2 Gio | 8 Go |
| VirtualBox | non installé | indispensable pour `vagrant up` |

Les deux VM du `Vagrantfile` demandent 5 Go de RAM à elles seules. J'ai donc appliqué le **plan B** du sujet : K3s directement sur la VM de lab, en **nœud unique**.

Un cluster K3s (v1.36.5+k3s1) existait déjà sur cette VM depuis 32 jours et héberge une autre application (`spring-app-deployment`, namespace `default`). Je ne l'ai pas désinstallé : le TP travaille dans son propre namespace `tp14`, sans conflit, et le playbook Ansible a été exécuté sur le cluster existant (il est idempotent). Les conséquences pour le rendu :

- `cluster-nodes.png` montre un seul nœud ;
- `rebuild.png` illustre l'**idempotence** du playbook (deuxième exécution, `changed=0`) à la place de `vagrant destroy -f && vagrant up` ;
- la question « sur quels nœuds sont répartis les Pods ? » a pour réponse « un seul » ;
- le Défi (troisième nœud, `drain`) n'est pas réalisable sur un nœud unique.

Le nom `whoami.lab.local` pointe vers l'adresse de Traefik sur la VM (`172.28.79.32`) dans `/etc/hosts`, au lieu de `192.168.56.10` qui n'existe pas en nœud unique.

---

## 2. Structure du rendu

Les fichiers du TP14 sont dans le dossier `tp14/` du dépôt, et ses captures dans `captures/tp14/` :

```
tp14/
├── k3s-lab/
│   ├── Vagrantfile
│   ├── playbook.yml
│   ├── inventory-local.ini
│   └── roles/k3s/
│       ├── defaults/main.yml
│       └── tasks/{server,agent}.yml
└── k8s-starter/
    ├── 01-namespace.yaml
    ├── 02-config.yaml
    ├── 03-deployment.yaml
    ├── 04-service.yaml
    ├── 05-ingress.yaml
    ├── 05b-api.yaml
    ├── 06-postgres.yaml
    └── 07-hpa.yaml
captures/tp14/            (captures d'écran du TP14)
```

Aucun fichier `k3s.yaml` (kubeconfig) et aucun Secret ne sont dans le dépôt : les Secrets sont créés en ligne de commande.

---

## 3. Partie 1 : cluster K3s avec Ansible

### 3.1 Architecture d'un cluster

| Composant | Rôle |
|---|---|
| API server | Point d'entrée unique : `kubectl` et tous les composants lui parlent. |
| Datastore | État du cluster (SQLite par défaut avec K3s, etcd en haute disponibilité). |
| Scheduler | Choisit le nœud de chaque Pod selon les ressources demandées. |
| Controllers | Boucles qui rapprochent l'état réel de l'état désiré (ReplicaSet, Deployment...). |
| kubelet | Agent de chaque nœud : démarre les conteneurs via containerd. |

### 3.2 Playbook

Le `playbook.yml` complété installe K3s en mode server de façon idempotente (`creates: /usr/local/bin/k3s`, avec `--node-ip`, `--tls-san` et `--write-kubeconfig-mode 644`), lit le jeton du server (`slurp`) et le stocke dans un fait (`set_fact`), rapatrie `k3s.yaml` (`fetch`) puis remplace `127.0.0.1` par l'adresse du server. Le play des agents (`K3S_URL`, `K3S_TOKEN`) est écrit mais ignoré en nœud unique (`skipping: no hosts matched`).

Comme `sudo` sur Ubuntu 26.04 gère mal l'invite de mot de passe d'Ansible (`Timed out waiting for become success`), j'ai lancé le playbook en root :

```bash
cd ~/k3s-lab
time sudo ansible-playbook -i inventory-local.ini -e k3s_server_ip=127.0.0.1 playbook.yml
```

Première exécution : `ok=8 changed=1 failed=0` (seul changement : le rapatriement de `k3s.yaml`), en 38 s.

![Cluster : nœud Ready, pods système, PLAY RECAP](captures/tp14/cluster-nodes.png)

Le nœud `wissal` est `Ready` (control-plane), et `coredns`, `traefik`, `local-path-provisioner` et `metrics-server` tournent.

### 3.3 Rôle `k3s`

Le playbook a été transformé en rôle : `roles/k3s/tasks/server.yml`, `tasks/agent.yml` et `defaults/main.yml`, qui épingle la version avec `k3s_version: "v1.36.5+k3s1"` (variable `INSTALL_K3S_VERSION`). Le playbook appelle les deux fichiers par `include_role` avec `tasks_from`.

Une remarque honnête : comme K3s était déjà installé, l'étape d'installation est ignorée, donc la version épinglée n'a pas été réellement exercée sur ce cluster.

### 3.4 Reconstruction et idempotence

Je n'ai pas détruit le cluster, car il héberge une autre application. J'ai donc démontré l'idempotence : après le passage au rôle, une nouvelle exécution du playbook donne `ok=9 changed=0 failed=0` (11 à 21 secondes), sans réinstaller K3s.

![Deuxième exécution du playbook : changed=0](captures/tp14/rebuild.png)

---

## 4. Partie 2 : Pods et Deployments

```bash
kubectl run test --image=traefik/whoami:v1.10.0
kubectl delete pod test
kubectl apply -f k8s-starter/01-namespace.yaml -f k8s-starter/03-deployment.yaml
```

**Le Pod lancé à la main est-il recréé ?** Non. Un Pod créé avec `kubectl run` n'a aucun contrôleur au-dessus de lui : une fois supprimé, personne ne le remet en place.

**Un Pod du Deployment est supprimé :** un nouveau Pod apparaît en 1 seconde, car le ReplicaSet maintient 2 réplicas. Le second Pod n'a pas bougé.

**Sur quels nœuds sont répartis les Pods ?** Sur un seul nœud (`wissal`), puisque le cluster n'en a qu'un.

**`kubectl exec -it ... -- sh`** échoue avec `exec: "sh": executable file not found in $PATH` : l'image `whoami` est minimale et ne contient pas de shell.

**`kubectl explain deployment.spec.strategy.rollingUpdate` :** `maxSurge` et `maxUnavailable` valent 25 % par défaut (arrondis respectivement à 1 par excès et 0 par défaut avec 2 réplicas).

`kubectl describe` montre dans `Events` : `Scheduled`, `Pulled`, `Created`, `Started`. Au départ, la classe de QoS est `BestEffort` (ni `requests` ni `limits`).

---

## 5. Partie 3 : Services et Ingress

Le Service `whoami` (`ClusterIP`, port 80 vers le port nommé `http`) reçoit le `selector` `app: whoami`. L'Ingress `traefik` route `whoami.lab.local/` vers ce Service.

Un second Service sert la route `/api` : `05b-api.yaml` contient une ConfigMap (`api-page`, qui apporte une page HTML), un Deployment `nginx:1.27-alpine` et le Service `api`. La règle `/api` est ajoutée à l'Ingress existant, dans le même fichier.

```bash
curl -s http://whoami.lab.local | head -4
curl -sL http://whoami.lab.local/api/
kubectl -n tp14 get svc,ingress
```

![Ingress : whoami et /api](captures/tp14/ingress.png)

La capture montre la réponse de `whoami` (Hostname et IP du Pod), la page de `/api/` servie par nginx, les deux Services `ClusterIP` et l'Ingress `traefik` pour `whoami.lab.local`.

| Type de Service | Accès |
|---|---|
| ClusterIP | Interne au cluster uniquement (par défaut). |
| NodePort | Port 30000 à 32767 ouvert sur chaque nœud. |
| LoadBalancer | IP externe (fournie par ServiceLB sur K3s, par le cloud ailleurs). |
| Ingress | Routage HTTP par nom d'hôte et chemin vers des Services ClusterIP. |

---

## 6. Partie 4 : ConfigMap et Secret

Le Secret est créé en ligne de commande (il n'est pas versionné) :

```bash
kubectl -n tp14 create secret generic whoami-secret --from-literal=api-key='lab-only-value'
kubectl -n tp14 get secret whoami-secret -o yaml
kubectl -n tp14 get secret whoami-secret -o jsonpath='{.data.api-key}' | base64 -d
```

La valeur apparaît en base64 (`bGFiLW9ubHktdmFsdWU=`) et `base64 -d` redonne immédiatement `lab-only-value`. **Base64 n'est pas du chiffrement** : la protection d'un Secret vient du contrôle d'accès (RBAC) et du chiffrement au repos du datastore.

La ConfigMap `whoami-config` (clés `WHOAMI_NAME` et `LOG_LEVEL`, TODO complété) est injectée avec `envFrom`, et la clé `api-key` du Secret par `secretKeyRef` (variable `API_KEY`). La page `whoami` avec `?env=true` affiche `API_KEY=lab-only-value`.

**La valeur change-t-elle dans les Pods existants après modification de la ConfigMap ?** Non. Test en une seule séquence (`WHOAMI_NAME` passe de `tp14-v2` à `tp14-v3`, et `LOG_LEVEL` de `info` à `debug`) :

![ConfigMap : avant, modification, après apply, restart, après restart](captures/tp14/configmap-restart.png)

| Étape | `Name` | `LOG_LEVEL` |
|---|---|---|
| 1. avant | `tp14-v2` | `info` |
| 3. après `apply`, sans redémarrer | `tp14-v2` (inchangé) | `info` (inchangé) |
| 5. après `kubectl rollout restart` | `tp14-v3` | `debug` |

Les variables d'environnement sont lues au démarrage du conteneur : il faut `kubectl rollout restart deploy/whoami` pour les renouveler.

---

## 7. Partie 5 : santé, ressources et déploiements progressifs

### 7.1 Probes et ressources

Le Deployment reçoit une `readinessProbe` (HTTP `/health`, toutes les 3 s, 2 échecs) et une `livenessProbe` (HTTP `/health`, toutes les 5 s, 3 échecs), ainsi que `requests` (50m CPU, 32Mi) et `limits` (200m CPU, 64Mi). La classe de QoS passe à `Burstable`.

![Probes, requests/limits et QoS Burstable](captures/tp14/probes-config.png)

### 7.2 Panne simulée

`whoami` permet de forcer le code de `/health` :

```bash
kubectl -n tp14 port-forward deploy/whoami 8081:8080 &
curl -X POST -d '500' localhost:8081/health
kubectl -n tp14 get pods -w
```

Séquence observée : le Pod passe à `0/1` (la `readinessProbe` échoue : il sort des endpoints du Service mais n'est pas tué), puis `RESTARTS` passe à `1` (la `livenessProbe` a échoué 3 fois, kubelet redémarre le conteneur), puis le Pod revient à `1/1`. Le second Pod a continué à servir.

![Pod redémarré par la livenessProbe : Unhealthy et Killing](captures/tp14/probes-restart.png)

Les `Events` indiquent `Readiness probe failed` (x6) et `Liveness probe failed` (x3) avec `statuscode: 500`, puis `Container whoami failed liveness probe, will be restarted`.

### 7.3 Rolling update et rollback

```bash
kubectl -n tp14 set image deploy/whoami whoami=traefik/whoami:v1.10.1
kubectl -n tp14 set image deploy/whoami whoami=traefik/whoami:v9.9.9   # image inexistante
kubectl -n tp14 get pods
kubectl -n tp14 rollout history deploy/whoami
kubectl -n tp14 rollout undo deploy/whoami
```

![Image inexistante, historique et rollback](captures/tp14/rollout-undo.png)

Le nouveau Pod est en `ImagePullBackOff` pendant que les deux anciens restent `Running`. `rollout undo` ramène l'image à `traefik/whoami:v1.10.1`. Une boucle de `curl` lancée pendant l'opération a reçu **35 réponses `200` sur 35** : aucune interruption.

Une remarque sur l'historique : l'annotation `change-cause` `update vers v1.10.1` apparaît sur plusieurs révisions. Elle est copiée d'une révision à l'autre tant qu'on ne la met pas à jour.

**Pourquoi le service n'a jamais été interrompu ?**

- `maxSurge` (25 %, arrondi à 1 avec 2 réplicas) : Kubernetes crée **d'abord** un nouveau Pod avant d'en retirer un ancien.
- `maxUnavailable` (25 %, arrondi à 0) : aucun ancien Pod ne peut être retiré tant qu'un nouveau n'est pas prêt.
- La `readinessProbe` : un Pod n'entre dans les endpoints du Service que s'il est `Ready`. Le Pod en `ImagePullBackOff` ne l'est jamais, donc il ne reçoit aucun trafic et les anciens Pods ne sont pas supprimés. Le déploiement reste bloqué, mais le service continue de fonctionner.

Le manifest `03-deployment.yaml` a été aligné sur l'image `v1.10.1` pour qu'un futur `kubectl apply` ne fasse pas redescendre la version.

### 7.4 OOMKilled

Avec `whoami`, les limites de **4 Mi** et **8 Mi** n'ont pas déclenché de `OOMKilled` : le Pod a démarré et est passé `Ready`, car ce binaire consomme très peu de mémoire. Le comportement a été démontré avec un Pod qui consomme volontairement de la mémoire (limite 16 Mi), qui a été tué :

![Pod tué par manque de mémoire : OOMKilled, exit code 137](captures/tp14/oomkilled.png)

`Reason: OOMKilled` et `Exit Code: 137` (128 + signal 9). Les valeurs d'origine ont été restaurées sur le Deployment (`limits` 200m / 64Mi, `requests` 50m / 32Mi).

---

## 8. Partie 6 : stockage persistant

### 8.1 Déploiement

Le Secret `postgres-secret` est créé en ligne de commande. Le montage du PVC `pgdata` (1 Gi, StorageClass `local-path`) est ajouté au Deployment `postgres` (`volumes` et `volumeMounts` sur `/var/lib/postgresql/data`). La stratégie `Recreate` est conservée : un volume `ReadWriteOnce` ne peut être monté que par un Pod à la fois. Le premier démarrage a pris 22 minutes à cause du téléchargement de l'image (connexion lente).

### 8.2 Test de persistance

```bash
kubectl -n tp14 exec deploy/postgres -- psql -U postgres \
  -c "CREATE TABLE IF NOT EXISTS visits(id serial PRIMARY KEY, page text);" \
  -c "INSERT INTO visits(page) VALUES ('/home'),('/contact');" \
  -c "SELECT * FROM visits;"
kubectl -n tp14 delete pod -l app=postgres
kubectl -n tp14 exec deploy/postgres -- psql -U postgres -c "SELECT * FROM visits;"
```

![La donnée survit à la suppression du Pod PostgreSQL](captures/tp14/pvc-persistence.png)

Le Pod a changé de nom (`zr9b4` puis `nm7tq`), mais les deux lignes `/home` et `/contact` sont toujours présentes : la donnée est sur le volume, pas dans le conteneur.

### 8.3 Où sont stockées les données ? Quelle limite ?

![PV, PVC, chemin et affinité de nœud](captures/tp14/pv-stockage.png)

- **Où ?** Dans un dossier du disque du nœud : `/var/lib/rancher/k3s/storage/pvc-9984b7bc-..._tp14_pgdata`. Ce n'est pas un stockage réseau.
- **Quelle limite ?** Le PV porte une **affinité de nœud** (`kubernetes.io/hostname in [wissal]`) : si le Pod était replanifié sur un autre nœud, il resterait `Pending`, car le volume ne le suit pas. Il n'y a ni réplication ni sauvegarde. Sur un nœud unique le problème ne se voit pas, mais il existe. Pour du multi-nœuds, il faut un stockage réseau (Longhorn, NFS, Ceph ou un stockage cloud).
- **`reclaimPolicy: Delete`** : supprimer le PVC supprime aussi le volume et ses données.

---

## 9. Partie 7 : HorizontalPodAutoscaler

`metrics-server` fonctionne (`kubectl top nodes` : 5 % de CPU, 59 % de mémoire). Le HPA `whoami` cible le Deployment `whoami` : minimum 2, maximum 6 réplicas, seuil de 50 % d'utilisation CPU (par rapport aux `requests`, ce qui exige que `requests.cpu` soit défini : 50m, donc environ 25m par Pod pour déclencher).

![metrics-server et manifest du HPA](captures/tp14/metrics-hpa-manifest.png)

Charge générée depuis un Pod `busybox` qui lance 4 boucles `wget` en parallèle contre `http://whoami` :

![Pods whoami et consommation CPU sous charge](captures/tp14/hpa-charge-pods.png)

Sous charge, `TARGETS` dépasse largement la cible (`160 %/50 %`) et `REPLICAS` monte au maximum (6). Chaque Pod `whoami` consomme environ 80 à 90m de CPU.

Après l'arrêt de la charge, l'utilisation retombe à 2 % et `REPLICAS` redescend de 6 à 3 puis à 2, environ cinq minutes plus tard : c'est la fenêtre de stabilisation par défaut du HPA (5 minutes), qui évite les oscillations.

![HPA : descente de 6 à 2 réplicas et historique des décisions](captures/tp14/hpa.png)

Les `Events` du HPA confirment : `New size: 4` puis `New size: 6` (`cpu resource utilization above target`), puis `New size: 3` et `New size: 2` (`All metrics below target`).

---

## 10. Défi

Non réalisé : le troisième nœud et `kubectl drain` supposent un cluster multi-nœuds. Sur mon nœud unique, un `drain` rendrait le nœud non planifiable et déplacerait aussi les autres applications du cluster. Le PodDisruptionBudget n'a pas été testé pour la même raison.

---

## 11. Difficultés rencontrées

- **Ressources insuffisantes pour Vagrant** (4 vCPU, 4,2 Gio de RAM, VirtualBox absent) : passage au plan B en nœud unique, sur un cluster K3s préexistant que j'ai conservé.
- **`sudo` et Ansible** : `Timed out waiting for become success or become password prompt`, probablement à cause du `sudo` de Ubuntu 26.04 ; contourné en lançant `ansible-playbook` en root.
- **Téléchargements lents** : une image de plusieurs dizaines de Mo prend plusieurs minutes (jusqu'à 22 minutes pour `postgres:17-alpine`). Un `rollout status` avec un délai de 180 secondes expirait donc alors que le déploiement continuait en arrière-plan.
- **PostgreSQL ne démarrait pas** : le conteneur restait `1/1 Running` sans que le serveur soit lancé (aucune ligne dans `logs`, processus `gosu` à 100 % de CPU). Après un passage en utilisateur non root (`runAsUser: 70`), l'erreur est devenue `could not signal for checkpoint: Permission denied`. Le journal du noyau (`dmesg`) contenait des refus `apparmor="DENIED" operation="signal"` pour le profil `cri-containerd.apparmor.d`. Ajouter `appArmorProfile: Unconfined` au `securityContext` du Pod a réglé le problème. C'est un contournement propre à cette VM, qui réduit l'isolation du conteneur ; ce n'est pas une bonne pratique générale. La cause du blocage initial dans `gosu` n'est pas établie avec certitude.
- **Limite mémoire de `whoami`** : 4 Mi et 8 Mi n'ont pas provoqué d'`OOMKilled`, d'où l'usage d'un Pod de démonstration.

---

## 12. Liste des captures

| Fichier | Contenu |
|---|---|
| `cluster-nodes.png` | Nœud `Ready`, pods système, `PLAY RECAP` de la première exécution |
| `rebuild.png` | Deuxième exécution du playbook : `changed=0` (idempotence) |
| `ingress.png` | `curl` sur `whoami.lab.local` et `/api`, Services et Ingress |
| `probes-restart.png` | Pod redémarré par la livenessProbe (`RESTARTS 1`, `Unhealthy`, `Killing`) |
| `rollout-undo.png` | `ImagePullBackOff`, `rollout history`, `rollout undo` |
| `pvc-persistence.png` | Donnée PostgreSQL conservée après suppression du Pod |
| `hpa.png` | HPA : descente de 6 à 2 réplicas et événements de mise à l'échelle |

Captures complémentaires :

| Fichier | Contenu |
|---|---|
| `configmap-restart.png` | ConfigMap : avant, après `apply`, après `rollout restart` |
| `probes-config.png` | Probes, `requests`/`limits` et QoS `Burstable` |
| `oomkilled.png` | Pod tué par manque de mémoire (`OOMKilled`, 137) |
| `pv-stockage.png` | PV, PVC, chemin sur le nœud et affinité de nœud |
| `metrics-hpa-manifest.png` | `kubectl top` et manifest du HPA |
| `hpa-charge-pods.png` | 6 Pods `whoami` et consommation CPU sous charge |
---

# TP15 : Packager une application Kubernetes avec Helm et Kustomize

[#tp15--packager-une-application-kubernetes-avec-helm-et-kustomize](#tp15--packager-une-application-kubernetes-avec-helm-et-kustomize)

**Auteur :** Wissal **Date :** 18 novembre 2026 **Environnement :** Ubuntu Server 26.04, K3s v1.36.5+k3s1 (nœud unique, TP14), Helm v3.22.1, `kubectl` avec Kustomize intégré

Une même application (`traefik/whoami`) est packagée de deux façons, avec Helm puis avec Kustomize, et les deux outils sont comparés.

---

## Sommaire

[#sommaire-2](#sommaire-2)

1. [Structure du rendu](#1-structure-du-rendu-1)
2. [Partie 1 : consommer un chart public](#2-partie-1--consommer-un-chart-public)
3. [Partie 2 : écrire son chart](#3-partie-2--écrire-son-chart)
4. [Partie 3 : cycle de vie d'une release](#4-partie-3--cycle-de-vie-dune-release)
5. [Partie 4 : Kustomize, base et overlays](#5-partie-4--kustomize-base-et-overlays)
6. [Partie 5 : comparaison Helm / Kustomize](#6-partie-5--comparaison-helm--kustomize)
7. [Défis](#7-défis)
8. [Difficultés rencontrées](#8-difficultés-rencontrées-1)
9. [Liste des captures](#9-liste-des-captures)

---

## 1. Structure du rendu

[#1-structure-du-rendu-1](#1-structure-du-rendu-1)

Les fichiers du TP15 sont dans le dossier `tp15/` du dépôt, et ses captures dans `captures/tp15/` :

```
tp15/
├── chart-starter/whoami/
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── values.schema.json          (défi)
│   └── templates/
│       ├── _helpers.tpl
│       ├── deployment.yaml
│       ├── service.yaml
│       ├── ingress.yaml
│       └── NOTES.txt
├── values-dev.yaml
├── values-prod.yaml
└── kustomize-starter/
    ├── base/
    │   ├── kustomization.yaml
    │   ├── deployment.yaml
    │   └── service.yaml
    └── overlays/
        ├── dev/
        ├── staging/
        └── prod/
captures/tp15/            (captures d'écran du TP15)
```

---

## 2. Partie 1 : consommer un chart public

[#2-partie-1--consommer-un-chart-public](#2-partie-1--consommer-un-chart-public)

```
helm repo add podinfo https://stefanprodan.github.io/podinfo && helm repo update
helm search repo podinfo
helm show values podinfo/podinfo | less
helm install demo podinfo/podinfo -n helm-demo --create-namespace --set replicaCount=2
helm list -A
helm get values demo -n helm-demo
helm get manifest demo -n helm-demo | head -40
kubectl -n helm-demo get secrets
helm uninstall demo -n helm-demo
```

- `helm get values` n'affiche que les **surcharges** (`replicaCount: 2`), alors que `helm get manifest` montre le YAML **réellement appliqué**.
- **Où Helm stocke-t-il l'historique d'une release ?** Dans des **Secrets** de type `helm.sh/release.v1`, **un par révision** (ici `sh.helm.release.v1.demo.v1`), dans le namespace de la release. Un `helm upgrade` crée `...v2`, et ainsi de suite.

Le déploiement a donné `2/2` pods `Running` (image `ghcr.io/stefanprodan/podinfo:6.17.0`).

---

## 3. Partie 2 : écrire son chart

[#3-partie-2--écrire-son-chart](#3-partie-2--écrire-son-chart)

**`version` et `appVersion`** : `version` (0.1.x) est la version du **chart** et doit être incrémentée à chaque modification des templates ou des values ; `appVersion` (`v1.10.0`) est la version de l'**application** et sert de tag d'image par défaut (`image.tag` vide).

Les TODO ont été complétés :

- `values.yaml` : ajout de la map `env` (`WHOAMI_NAME`).
- `deployment.yaml` : bloc `env:` généré par `with` et `range $name, $value := .` (valeurs forcées en chaîne avec `quote`), `readinessProbe` et `livenessProbe` HTTP sur `/health` (port nommé `http`).
- `service.yaml` : nom, labels, type et port viennent des helpers et de `.Values.service`, `selector` avec `whoami.selectorLabels` et `targetPort: http`.
- `ingress.yaml` : généré **seulement si** `ingress.enabled` vaut `true` (`ingressClassName`, `host`, backend vers le Service du chart).

Les `selectorLabels` (nom et instance) ne contiennent ni version ni numéro de chart : le `selector` d'un Deployment est **immuable** et ne doit pas changer entre deux versions.

| Fonction Helm utilisée | Usage dans le chart                                                       |
| ---------------------- | ------------------------------------------------------------------------- |
| `include` + `nindent`  | Insérer les helpers de labels avec la bonne indentation                   |
| `default`              | `.Values.image.tag \| default .Chart.AppVersion`                          |
| `toYaml`               | Recopier le bloc `resources` tel quel                                     |
| `quote`                | Forcer une chaîne pour les valeurs d'`env`                                |

Validation :

```
helm lint chart-starter/whoami
helm template test chart-starter/whoami --set ingress.enabled=true | less
helm install test chart-starter/whoami --dry-run=server -n tp15 --create-namespace
```

`helm lint` : `1 chart(s) linted, 0 chart(s) failed` (seul message : `[INFO] icon is recommended`). Le rendu contient l'image `traefik/whoami:v1.10.0` (tag par défaut = `appVersion`), l'`env`, les deux probes et les `resources`. Avec `--set ingress.enabled=true`, l'Ingress apparaît (`ingressClassName: traefik`, `host: "whoami.lab.local"`). Le `--dry-run=server` est accepté par le serveur d'API sans rien déployer (release en `pending-install`).

[![helm lint, helm template et Ingress généré](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp15/helm-lint-template.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp15/helm-lint-template.png)

---

## 4. Partie 3 : cycle de vie d'une release

[#4-partie-3--cycle-de-vie-dune-release](#4-partie-3--cycle-de-vie-dune-release)

`values-dev.yaml` (1 replica, Ingress activé, `WHOAMI_NAME: dev`) et `values-prod.yaml` (3 replicas, `limits` plus élevées) ont été créés. Seul `values-dev.yaml` a été installé sur le cluster.

```
helm install whoami chart-starter/whoami -n tp15 --create-namespace -f values-dev.yaml
curl http://whoami.lab.local
helm upgrade whoami chart-starter/whoami -n tp15 -f values-dev.yaml --set replicaCount=3
helm upgrade whoami chart-starter/whoami -n tp15 -f values-dev.yaml --set image.tag=v9.9.9
kubectl -n tp15 get pods
helm history whoami -n tp15
helm rollback whoami 2 -n tp15
helm history whoami -n tp15
```

| Révision | Action                          | Résultat observé                                                                                      |
| -------- | ------------------------------- | ----------------------------------------------------------------------------------------------------- |
| 1        | `install`                       | `curl http://whoami.lab.local` répond `Name: dev`                                                     |
| 2        | `upgrade` (`replicaCount=3`)    | 3 pods `Running`                                                                                      |
| 3        | `upgrade` (`image.tag=v9.9.9`)  | Nouveau pod en `ErrImagePull`, ancien pod toujours `Running` ; Helm affiche pourtant `STATUS: deployed` |
| 4        | `rollback` vers la révision 2   | Description `Rollback to 2`, révisions 1 à 3 conservées                                               |

**Le rollback crée une NOUVELLE révision** (la 4, copie de la 2) : l'historique n'est jamais effacé. Sans `--atomic` ni `--wait`, Helm considère l'upgrade réussi dès que les manifests sont appliqués, sans vérifier la santé des pods.

[![helm history après upgrade, échec et rollback](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp15/helm-history.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp15/helm-history.png)

### Mise à jour défaillante avec `--atomic`

[#mise-à-jour-défaillante-avec---atomic](#mise-à-jour-défaillante-avec---atomic)

```
helm upgrade whoami chart-starter/whoami -n tp15 -f values-dev.yaml \
  --set image.tag=v9.9.9 --atomic --timeout 90s
```

**Que fait Helm cette fois-ci ?** Il attend que les nouveaux pods deviennent `Ready`, constate qu'ils n'y arrivent pas (`ErrImagePull`), déclare la révision en `failed` puis **revient seul à la version précédente** : `release whoami failed, and has been rolled back due to atomic being set`. Le dernier `helm history` montre une révision `failed` (8) suivie d'une révision `Rollback to 7` (9) en `deployed`, avec 3 pods `Running`.

Avec `--timeout 60s`, le rollback automatique a lui-même échoué (`an error occurred while rolling back the release`) : le retour arrière consomme le même délai, qui était déjà écoulé. La release est restée en `failed` (révision 6) et a été remise d'aplomb avec `helm rollback whoami 4 --wait --timeout 120s` (révision 7). Un délai de 90 s a suffi pour la reprise propre.

[![Upgrade --atomic annulé automatiquement](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp15/helm-atomic.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp15/helm-atomic.png)

### Empaquetage

[#empaquetage](#empaquetage)

```
helm package chart-starter/whoami        # whoami-0.1.0.tgz
sed -i 's/^version: 0.1.0/version: 0.1.1/' chart-starter/whoami/Chart.yaml
helm package chart-starter/whoami        # whoami-0.1.1.tgz
```

Le nom de l'archive suit `version` de `Chart.yaml`, pas `appVersion` : c'est ce numéro qu'un dépôt de charts utilise pour distinguer les versions.

---

## 5. Partie 4 : Kustomize, base et overlays

[#5-partie-4--kustomize-base-et-overlays](#5-partie-4--kustomize-base-et-overlays)

La **base** contient le Deployment, le Service et un `configMapGenerator` (`whoami-config`) ; elle ajoute le label `app.kubernetes.io/part-of: tp15` avec `includeSelectors: false` (les selectors ne changent pas). Chaque **overlay** ne contient que les différences :

| Overlay   | Namespace      | Replicas | Particularités                                                                  |
| --------- | -------------- | -------- | ------------------------------------------------------------------------------- |
| `dev`     | `tp15-dev`     | 1        | `WHOAMI_NAME=dev`, `LOG_LEVEL=debug` (fourni)                                   |
| `staging` | `tp15-staging` | 2        | `WHOAMI_NAME=staging`, `LOG_LEVEL=info`                                         |
| `prod`    | `tp15-prod`    | 3        | image `v1.10.1` (champ `images`), `limits.memory: 128Mi` (patch), `readinessProbe` (patch stratégique dans `readiness-patch.yaml`) |

La prévisualisation (`kubectl kustomize`) montre :

- le **namespace** appliqué à toutes les ressources ;
- un ConfigMap au nom suffixé d'un **hash** (`whoami-config-6t5d5gdccm` pour dev), dont le nom est **réécrit automatiquement** dans `envFrom` du Deployment ;
- le label `app.kubernetes.io/part-of: tp15` ajouté partout.

Déploiement et comparaison :

```
kubectl apply -k kustomize-starter/overlays/dev
kubectl apply -k kustomize-starter/overlays/staging
kubectl apply -k kustomize-starter/overlays/prod
kubectl get deploy -A -l app.kubernetes.io/part-of=tp15
diff <(kubectl kustomize kustomize-starter/overlays/staging) <(kubectl kustomize kustomize-starter/overlays/prod)
```

Résultat : `tp15-dev` 1/1, `tp15-staging` 2/2, `tp15-prod` 3/3.

[![Trois Deployments avec des replicas différents](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp15/kustomize-envs.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp15/kustomize-envs.png)

Le `diff` staging / prod montre exactement les écarts attendus : namespace, hash et contenu du ConfigMap, replicas (2 contre 3), tag d'image (`v1.10.0` contre `v1.10.1`), `readinessProbe` (prod seulement) et `limits.memory` (64Mi contre 128Mi).

[![diff staging / prod](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp15/kustomize-diff.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp15/kustomize-diff.png)

### Pourquoi les Pods sont-ils recréés quand `LOG_LEVEL` change ?

[#pourquoi-les-pods-sont-ils-recréés-quand-log_level-change-](#pourquoi-les-pods-sont-ils-recréés-quand-log_level-change-)

`LOG_LEVEL` passe de `debug` à `trace` dans l'overlay dev, puis `kubectl apply -k` est relancé :

- le contenu du ConfigMap change, donc son **hash** change, donc son **nom** : `whoami-config-6t5d5gdccm` devient `whoami-config-9mtdt796g2` ;
- Kustomize réécrit ce nom dans `envFrom` du Deployment (`deployment.apps/whoami configured`), ce qui **modifie le template de Pod** ;
- Kubernetes fait un rolling update : le nouveau pod devient `Running`, puis l'ancien est terminé.

Dans le TP14, le ConfigMap avait un **nom fixe** : modifier ses données ne changeait pas le Deployment, donc aucun Pod n'était recréé sans `kubectl rollout restart`.

Vérification : le Deployment référence `whoami-config-9mtdt796g2`, qui contient `{"LOG_LEVEL":"trace","WHOAMI_NAME":"dev"}`, et un `port-forward` sur le pod renvoie `Name: dev`. L'ancien ConfigMap reste en place, car `kubectl apply -k` ne supprime rien sans `--prune`.

---

## 6. Partie 5 : comparaison Helm / Kustomize

[#6-partie-5--comparaison-helm--kustomize](#6-partie-5--comparaison-helm--kustomize)

| Critère                               | Helm                                                                              | Kustomize                                                                       |
| ------------------------------------- | --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| Mécanisme (template / patch)          | Templates Go + fichiers `values` : le YAML est généré                             | Patches et transformateurs appliqués à une base en YAML pur, sans template      |
| Gestion des releases et rollback      | Oui : révisions stockées dans des Secrets, `history`, `rollback`, `--atomic`      | Non : pas de notion de release, le retour arrière passe par Git ou `kubectl rollout undo` |
| Distribution d'un logiciel à des tiers | Très adapté : charts versionnés, dépôts, registres OCI, `helm install`           | Peu adapté : dossiers ou dépôts Git, sans versionnement de paquet               |
| Lisibilité du YAML final              | Moyenne : les templates mélangent YAML et logique (`{{ }}`, `nindent`)            | Bonne : la base est du YAML valide, les overlays ne contiennent que les différences |
| Intégré à kubectl                     | Non : binaire séparé à installer                                                  | Oui : `kubectl apply -k` et `kubectl kustomize`                                 |
| Support par Argo CD                   | Oui, natif                                                                        | Oui, natif                                                                      |

**Quand utiliser les deux ensemble ?** Pour déployer un chart tiers en l'adaptant sans le forker : on déclare le chart avec `helmCharts:` dans une `kustomization.yaml`, ou on fait `helm template` puis on applique des patches Kustomize (labels, `resources`, sidecar). Helm apporte le paquet, Kustomize la personnalisation par environnement.

---

## 7. Défis

[#7-défis](#7-défis)

### Défi 1 : `values.schema.json` (réalisé)

[#défi-1--valuesschemajson-réalisé](#défi-1--valuesschemajson-réalisé)

Un schéma JSON (`replicaCount` entier d'au moins 1, `containerPort` entier, `image.repository` et `image.tag` chaînes, `ingress.enabled` booléen) valide les values avant tout rendu.

```
helm lint chart-starter/whoami                                   # 0 chart(s) failed
helm lint chart-starter/whoami --set replicaCount=trois          # at '/replicaCount': got string, want integer
helm template test chart-starter/whoami --set replicaCount=0     # at '/replicaCount': minimum: got 0, want 1
helm template test chart-starter/whoami --set replicaCount=2    # replicas: 2
```

Le schéma bloque donc aussi `helm template` et `helm install`, pas seulement `helm lint`.

[![helm lint refuse replicaCount: "trois"](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp15/helm-schema.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp15/helm-schema.png)

### Défi 2 : registre OCI Harbor (non réalisé)

[#défi-2--registre-oci-harbor-non-réalisé](#défi-2--registre-oci-harbor-non-réalisé)

Au moment du TP, seul le conteneur `harbor-log` tournait : les autres conteneurs Harbor (`nginx`, `core`, `registry`) étaient arrêtés, et `https://harbor.lab.local/api/v2.0/health` renvoyait `404` (c'est le Traefik de K3s qui répond sur les ports 80 et 443, pas Harbor). Le `helm push` vers `oci://harbor.lab.local/devsecops` n'a donc pas été testé. Un registre `local-registry` tourne sur le port 5000 et pourrait servir de substitut avec `--plain-http`.

---

## 8. Difficultés rencontrées

[#8-difficultés-rencontrées-1](#8-difficultés-rencontrées-1)

- **Pull d'image très lent** : les pods `podinfo` sont restés plusieurs minutes en `ContainerCreating` (événement `Pulling image` sans suite), sur une résolution DNS64 (`64:ff9b::`) de `ghcr.io`. Résolu en pré-téléchargeant l'image avec `sudo k3s crictl pull`, puis en faisant de même pour `traefik/whoami` avant les parties suivantes.
- **`--atomic --timeout 60s`** : le rollback automatique a échoué faute de temps (release en `failed`). Réparation par `helm rollback ... --wait --timeout 120s`, puis nouvel essai réussi avec `--timeout 90s`.
- **`kubectl exec ... -- env` impossible** : l'image `traefik/whoami` ne contient aucun binaire (`executable file not found in $PATH`). La valeur de `LOG_LEVEL` a été vérifiée avec `jsonpath` sur le Deployment et le ConfigMap, et `WHOAMI_NAME` avec un `port-forward`.
- **Port local 8080 déjà utilisé** par un Jenkins (`address already in use`) : le `curl` interrogeait Jenkins sans que l'on s'en aperçoive. Solution : `port-forward` sur le port 18080.
- **Chevrons laissés dans les commandes** : `<IP>` et `<tag>` d'un énoncé sont des emplacements à remplacer, ce qui a fait échouer l'entrée `/etc/hosts` et un `crictl pull`.
- **Fichiers de départ absents de la VM** : `chart-starter.zip` et `kustomize-starter.zip` étaient sur Windows, copiés avec `scp` avant extraction.
- **Harbor arrêté** : voir le défi 2.

---

## 9. Liste des captures

[#9-liste-des-captures](#9-liste-des-captures)

| Fichier                   | Contenu                                                              |
| ------------------------- | -------------------------------------------------------------------- |
| `helm-lint-template.png`  | `helm lint` sans erreur, extrait de `helm template` et Ingress       |
| `helm-history.png`        | `helm history` après upgrade, échec et rollback                      |
| `helm-atomic.png`         | Upgrade `--atomic` annulé automatiquement                            |
| `kustomize-envs.png`      | Trois Deployments (dev / staging / prod) avec des replicas différents |
| `kustomize-diff.png`      | `diff` staging / prod                                                |
| `helm-schema.png`         | `helm lint` refusant `replicaCount: "trois"` (défi 1)                |
---

# TP15 : Packager une application Kubernetes avec Helm et Kustomize

[#tp15--packager-une-application-kubernetes-avec-helm-et-kustomize](#tp15--packager-une-application-kubernetes-avec-helm-et-kustomize)

**Auteur :** Wissal **Date :** 18 novembre 2026 **Environnement :** Ubuntu Server 26.04, K3s v1.36.5+k3s1 (nœud unique, TP14), Helm v3.22.1, `kubectl` avec Kustomize intégré

Une même application (`traefik/whoami`) est packagée de deux façons, avec Helm puis avec Kustomize, et les deux outils sont comparés.

---

## Sommaire

[#sommaire-2](#sommaire-2)

1. [Structure du rendu](#1-structure-du-rendu-1)
2. [Partie 1 : consommer un chart public](#2-partie-1--consommer-un-chart-public)
3. [Partie 2 : écrire son chart](#3-partie-2--écrire-son-chart)
4. [Partie 3 : cycle de vie d'une release](#4-partie-3--cycle-de-vie-dune-release)
5. [Partie 4 : Kustomize, base et overlays](#5-partie-4--kustomize-base-et-overlays)
6. [Partie 5 : comparaison Helm / Kustomize](#6-partie-5--comparaison-helm--kustomize)
7. [Défis](#7-défis)
8. [Difficultés rencontrées](#8-difficultés-rencontrées-1)
9. [Liste des captures](#9-liste-des-captures)

---

## 1. Structure du rendu

[#1-structure-du-rendu-1](#1-structure-du-rendu-1)

Les fichiers du TP15 sont dans le dossier `tp15/` du dépôt, et ses captures dans `captures/tp15/` :

```
tp15/
├── chart-starter/whoami/
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── values.schema.json          (défi)
│   └── templates/
│       ├── _helpers.tpl
│       ├── deployment.yaml
│       ├── service.yaml
│       ├── ingress.yaml
│       └── NOTES.txt
├── values-dev.yaml
├── values-prod.yaml
└── kustomize-starter/
    ├── base/
    │   ├── kustomization.yaml
    │   ├── deployment.yaml
    │   └── service.yaml
    └── overlays/
        ├── dev/
        ├── staging/
        └── prod/
captures/tp15/            (captures d'écran du TP15)
```

---

## 2. Partie 1 : consommer un chart public

[#2-partie-1--consommer-un-chart-public](#2-partie-1--consommer-un-chart-public)

```
helm repo add podinfo https://stefanprodan.github.io/podinfo && helm repo update
helm search repo podinfo
helm show values podinfo/podinfo | less
helm install demo podinfo/podinfo -n helm-demo --create-namespace --set replicaCount=2
helm list -A
helm get values demo -n helm-demo
helm get manifest demo -n helm-demo | head -40
kubectl -n helm-demo get secrets
helm uninstall demo -n helm-demo
```

- `helm get values` n'affiche que les **surcharges** (`replicaCount: 2`), alors que `helm get manifest` montre le YAML **réellement appliqué**.
- **Où Helm stocke-t-il l'historique d'une release ?** Dans des **Secrets** de type `helm.sh/release.v1`, **un par révision** (ici `sh.helm.release.v1.demo.v1`), dans le namespace de la release. Un `helm upgrade` crée `...v2`, et ainsi de suite.

Le déploiement a donné `2/2` pods `Running` (image `ghcr.io/stefanprodan/podinfo:6.17.0`).

[![podinfo : 2 pods Running et replicaCount: 2](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp15/helm-podinfo-pods.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp15/helm-podinfo-pods.png)

---

## 3. Partie 2 : écrire son chart

[#3-partie-2--écrire-son-chart](#3-partie-2--écrire-son-chart)

**`version` et `appVersion`** : `version` (0.1.x) est la version du **chart** et doit être incrémentée à chaque modification des templates ou des values ; `appVersion` (`v1.10.0`) est la version de l'**application** et sert de tag d'image par défaut (`image.tag` vide).

Les TODO ont été complétés :

- `values.yaml` : ajout de la map `env` (`WHOAMI_NAME`).
- `deployment.yaml` : bloc `env:` généré par `with` et `range $name, $value := .` (valeurs forcées en chaîne avec `quote`), `readinessProbe` et `livenessProbe` HTTP sur `/health` (port nommé `http`).
- `service.yaml` : nom, labels, type et port viennent des helpers et de `.Values.service`, `selector` avec `whoami.selectorLabels` et `targetPort: http`.
- `ingress.yaml` : généré **seulement si** `ingress.enabled` vaut `true` (`ingressClassName`, `host`, backend vers le Service du chart).

Les `selectorLabels` (nom et instance) ne contiennent ni version ni numéro de chart : le `selector` d'un Deployment est **immuable** et ne doit pas changer entre deux versions.

| Fonction Helm utilisée | Usage dans le chart                                                       |
| ---------------------- | ------------------------------------------------------------------------- |
| `include` + `nindent`  | Insérer les helpers de labels avec la bonne indentation                   |
| `default`              | `.Values.image.tag \| default .Chart.AppVersion`                          |
| `toYaml`               | Recopier le bloc `resources` tel quel                                     |
| `quote`                | Forcer une chaîne pour les valeurs d'`env`                                |

Validation :

```
helm lint chart-starter/whoami
helm template test chart-starter/whoami --set ingress.enabled=true | less
helm install test chart-starter/whoami --dry-run=server -n tp15 --create-namespace
```

`helm lint` : `1 chart(s) linted, 0 chart(s) failed` (seul message : `[INFO] icon is recommended`). Le rendu contient l'image `traefik/whoami:v1.10.0` (tag par défaut = `appVersion`), l'`env`, les deux probes et les `resources`. Avec `--set ingress.enabled=true`, l'Ingress apparaît (`ingressClassName: traefik`, `host: "whoami.lab.local"`). Le `--dry-run=server` est accepté par le serveur d'API sans rien déployer (release en `pending-install`).

[![helm lint sans erreur](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp15/helm-lint.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp15/helm-lint.png)

[![dry-run=server (début)](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp15/helm-dry-run-debut.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp15/helm-dry-run-debut.png)

[![dry-run=server (fin, NOTES)](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp15/helm-dry-run-fin.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp15/helm-dry-run-fin.png)

[![helm lint, helm template et Ingress généré](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp15/helm-lint-template.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp15/helm-lint-template.png)

---

## 4. Partie 3 : cycle de vie d'une release

[#4-partie-3--cycle-de-vie-dune-release](#4-partie-3--cycle-de-vie-dune-release)

`values-dev.yaml` (1 replica, Ingress activé, `WHOAMI_NAME: dev`) et `values-prod.yaml` (3 replicas, `limits` plus élevées) ont été créés. Seul `values-dev.yaml` a été installé sur le cluster.

```
helm install whoami chart-starter/whoami -n tp15 --create-namespace -f values-dev.yaml
curl http://whoami.lab.local
helm upgrade whoami chart-starter/whoami -n tp15 -f values-dev.yaml --set replicaCount=3
helm upgrade whoami chart-starter/whoami -n tp15 -f values-dev.yaml --set image.tag=v9.9.9
kubectl -n tp15 get pods
helm history whoami -n tp15
helm rollback whoami 2 -n tp15
helm history whoami -n tp15
```

| Révision | Action                          | Résultat observé                                                                                      |
| -------- | ------------------------------- | ----------------------------------------------------------------------------------------------------- |
| 1        | `install`                       | `curl http://whoami.lab.local` répond `Name: dev`                                                     |
| 2        | `upgrade` (`replicaCount=3`)    | 3 pods `Running`                                                                                      |
| 3        | `upgrade` (`image.tag=v9.9.9`)  | Nouveau pod en `ErrImagePull`, ancien pod toujours `Running` ; Helm affiche pourtant `STATUS: deployed` |
| 4        | `rollback` vers la révision 2   | Description `Rollback to 2`, révisions 1 à 3 conservées                                               |

**Le rollback crée une NOUVELLE révision** (la 4, copie de la 2) : l'historique n'est jamais effacé. Sans `--atomic` ni `--wait`, Helm considère l'upgrade réussi dès que les manifests sont appliqués, sans vérifier la santé des pods.

[![Révision 1 : install et curl (Name: dev)](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp15/helm-install-dev.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp15/helm-install-dev.png)

[![Révision 2 : 3 pods](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp15/helm-upgrade-rev2.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp15/helm-upgrade-rev2.png)

[![Révision 3 : ErrImagePull, ancien pod toujours Running](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp15/helm-upgrade-rev3-echec.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp15/helm-upgrade-rev3-echec.png)

[![helm history après upgrade, échec et rollback](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp15/helm-history.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp15/helm-history.png)

### Mise à jour défaillante avec `--atomic`

[#mise-à-jour-défaillante-avec---atomic](#mise-à-jour-défaillante-avec---atomic)

```
helm upgrade whoami chart-starter/whoami -n tp15 -f values-dev.yaml \
  --set image.tag=v9.9.9 --atomic --timeout 90s
```

**Que fait Helm cette fois-ci ?** Il attend que les nouveaux pods deviennent `Ready`, constate qu'ils n'y arrivent pas (`ErrImagePull`), déclare la révision en `failed` puis **revient seul à la version précédente** : `release whoami failed, and has been rolled back due to atomic being set`. Le test a été refait sur une release réinstallée (historique repartant de 1) : `helm history` montre une révision `failed` (4, `context deadline exceeded`) suivie d'une révision `Rollback to 3` (5) en `deployed`, et le pod est `1/1 Running`, sans pod en erreur. La révision 2 `failed` (`context canceled`) correspond à une première tentative interrompue avant la fin ; elle a été annulée par Helm (révision 3, `Rollback to 1`).

Avec `--timeout 60s`, le rollback automatique a lui-même échoué (`an error occurred while rolling back the release`) : le retour arrière consomme le même délai, qui était déjà écoulé. La release est restée en `failed` (révision 6) et a été remise d'aplomb avec `helm rollback whoami 4 --wait --timeout 120s` (révision 7). Un délai de 90 s a suffi pour la reprise propre.

[![Historique du premier essai (timeout 60 s puis 90 s)](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp15/helm-atomic-historique.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp15/helm-atomic-historique.png)

[![Upgrade --atomic annulé automatiquement](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp15/helm-atomic.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp15/helm-atomic.png)

### Empaquetage

[#empaquetage](#empaquetage)

```
helm package chart-starter/whoami        # whoami-0.1.0.tgz
sed -i 's/^version: 0.1.0/version: 0.1.1/' chart-starter/whoami/Chart.yaml
helm package chart-starter/whoami        # whoami-0.1.1.tgz
```

Le nom de l'archive suit `version` de `Chart.yaml`, pas `appVersion` : c'est ce numéro qu'un dépôt de charts utilise pour distinguer les versions.

[![helm package 0.1.0](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp15/helm-package-0.1.0.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp15/helm-package-0.1.0.png)

[![helm package 0.1.1](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp15/helm-package-0.1.1.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp15/helm-package-0.1.1.png)

---

## 5. Partie 4 : Kustomize, base et overlays

[#5-partie-4--kustomize-base-et-overlays](#5-partie-4--kustomize-base-et-overlays)

La **base** contient le Deployment, le Service et un `configMapGenerator` (`whoami-config`) ; elle ajoute le label `app.kubernetes.io/part-of: tp15` avec `includeSelectors: false` (les selectors ne changent pas). Chaque **overlay** ne contient que les différences :

| Overlay   | Namespace      | Replicas | Particularités                                                                  |
| --------- | -------------- | -------- | ------------------------------------------------------------------------------- |
| `dev`     | `tp15-dev`     | 1        | `WHOAMI_NAME=dev`, `LOG_LEVEL=debug` (fourni)                                   |
| `staging` | `tp15-staging` | 2        | `WHOAMI_NAME=staging`, `LOG_LEVEL=info`                                         |
| `prod`    | `tp15-prod`    | 3        | image `v1.10.1` (champ `images`), `limits.memory: 128Mi` (patch), `readinessProbe` (patch stratégique dans `readiness-patch.yaml`) |

La prévisualisation (`kubectl kustomize`) montre :

- le **namespace** appliqué à toutes les ressources ;
- un ConfigMap au nom suffixé d'un **hash** (`whoami-config-6t5d5gdccm` pour dev), dont le nom est **réécrit automatiquement** dans `envFrom` du Deployment ;
- le label `app.kubernetes.io/part-of: tp15` ajouté partout.

Déploiement et comparaison :

```
kubectl apply -k kustomize-starter/overlays/dev
kubectl apply -k kustomize-starter/overlays/staging
kubectl apply -k kustomize-starter/overlays/prod
kubectl get deploy -A -l app.kubernetes.io/part-of=tp15
diff <(kubectl kustomize kustomize-starter/overlays/staging) <(kubectl kustomize kustomize-starter/overlays/prod)
```

Résultat : `tp15-dev` 1/1, `tp15-staging` 2/2, `tp15-prod` 3/3.

[![Trois Deployments avec des replicas différents](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp15/kustomize-envs.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp15/kustomize-envs.png)

Le `diff` staging / prod montre exactement les écarts attendus : namespace, hash et contenu du ConfigMap, replicas (2 contre 3), tag d'image (`v1.10.0` contre `v1.10.1`), `readinessProbe` (prod seulement) et `limits.memory` (64Mi contre 128Mi).

[![diff staging / prod](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp15/kustomize-diff.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp15/kustomize-diff.png)

### Pourquoi les Pods sont-ils recréés quand `LOG_LEVEL` change ?

[#pourquoi-les-pods-sont-ils-recréés-quand-log_level-change-](#pourquoi-les-pods-sont-ils-recréés-quand-log_level-change-)

`LOG_LEVEL` passe de `debug` à `trace` dans l'overlay dev, puis `kubectl apply -k` est relancé :

- le contenu du ConfigMap change, donc son **hash** change, donc son **nom** : `whoami-config-6t5d5gdccm` devient `whoami-config-9mtdt796g2` ;
- Kustomize réécrit ce nom dans `envFrom` du Deployment (`deployment.apps/whoami configured`), ce qui **modifie le template de Pod** ;
- Kubernetes fait un rolling update : le nouveau pod devient `Running`, puis l'ancien est terminé.

Dans le TP14, le ConfigMap avait un **nom fixe** : modifier ses données ne changeait pas le Deployment, donc aucun Pod n'était recréé sans `kubectl rollout restart`.

Vérification : le Deployment référence `whoami-config-9mtdt796g2`, qui contient `{"LOG_LEVEL":"trace","WHOAMI_NAME":"dev"}`, et un `port-forward` sur le pod renvoie `Name: dev`. L'ancien ConfigMap reste en place, car `kubectl apply -k` ne supprime rien sans `--prune`.

[![Déploiement des trois overlays](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp15/kustomize-apply.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp15/kustomize-apply.png)

[![ConfigMap whoami-config-9mtdt796g2 utilisé par le Deployment](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp15/kustomize-configmap-verif.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp15/kustomize-configmap-verif.png)

[![port-forward : Name: dev](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp15/kustomize-port-forward-ok.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp15/kustomize-port-forward-ok.png)

---

## 6. Partie 5 : comparaison Helm / Kustomize

[#6-partie-5--comparaison-helm--kustomize](#6-partie-5--comparaison-helm--kustomize)

| Critère                               | Helm                                                                              | Kustomize                                                                       |
| ------------------------------------- | --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| Mécanisme (template / patch)          | Templates Go + fichiers `values` : le YAML est généré                             | Patches et transformateurs appliqués à une base en YAML pur, sans template      |
| Gestion des releases et rollback      | Oui : révisions stockées dans des Secrets, `history`, `rollback`, `--atomic`      | Non : pas de notion de release, le retour arrière passe par Git ou `kubectl rollout undo` |
| Distribution d'un logiciel à des tiers | Très adapté : charts versionnés, dépôts, registres OCI, `helm install`           | Peu adapté : dossiers ou dépôts Git, sans versionnement de paquet               |
| Lisibilité du YAML final              | Moyenne : les templates mélangent YAML et logique (`{{ }}`, `nindent`)            | Bonne : la base est du YAML valide, les overlays ne contiennent que les différences |
| Intégré à kubectl                     | Non : binaire séparé à installer                                                  | Oui : `kubectl apply -k` et `kubectl kustomize`                                 |
| Support par Argo CD                   | Oui, natif                                                                        | Oui, natif                                                                      |

**Quand utiliser les deux ensemble ?** Pour déployer un chart tiers en l'adaptant sans le forker : on déclare le chart avec `helmCharts:` dans une `kustomization.yaml`, ou on fait `helm template` puis on applique des patches Kustomize (labels, `resources`, sidecar). Helm apporte le paquet, Kustomize la personnalisation par environnement.

---

## 7. Défis

[#7-défis](#7-défis)

### Défi 1 : `values.schema.json` (réalisé)

[#défi-1--valuesschemajson-réalisé](#défi-1--valuesschemajson-réalisé)

Un schéma JSON (`replicaCount` entier d'au moins 1, `containerPort` entier, `image.repository` et `image.tag` chaînes, `ingress.enabled` booléen) valide les values avant tout rendu.

```
helm lint chart-starter/whoami                                   # 0 chart(s) failed
helm lint chart-starter/whoami --set replicaCount=trois          # at '/replicaCount': got string, want integer
helm template test chart-starter/whoami --set replicaCount=0     # at '/replicaCount': minimum: got 0, want 1
helm template test chart-starter/whoami --set replicaCount=2    # replicas: 2
```

Le schéma bloque donc aussi `helm template` et `helm install`, pas seulement `helm lint`.

[![values.schema.json présent dans le chart](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp15/helm-schema-fichiers.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp15/helm-schema-fichiers.png)

[![helm template refuse trois et 0](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp15/helm-schema-template.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp15/helm-schema-template.png)

[![helm lint refuse replicaCount: "trois"](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp15/helm-schema.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp15/helm-schema.png)

### Défi 2 : registre OCI Harbor (non réalisé)

[#défi-2--registre-oci-harbor-non-réalisé](#défi-2--registre-oci-harbor-non-réalisé)

Au moment du TP, seul le conteneur `harbor-log` tournait : les autres conteneurs Harbor (`nginx`, `core`, `registry`) étaient arrêtés, et `https://harbor.lab.local/api/v2.0/health` renvoyait `404` (c'est le Traefik de K3s qui répond sur les ports 80 et 443, pas Harbor). Le `helm push` vers `oci://harbor.lab.local/devsecops` n'a donc pas été testé. Un registre `local-registry` tourne sur le port 5000 et pourrait servir de substitut avec `--plain-http`.

---

## 8. Difficultés rencontrées

[#8-difficultés-rencontrées-1](#8-difficultés-rencontrées-1)

- **Pull d'image très lent** : les pods `podinfo` sont restés plusieurs minutes en `ContainerCreating` (événement `Pulling image` sans suite), sur une résolution DNS64 (`64:ff9b::`) de `ghcr.io`. Résolu en pré-téléchargeant l'image avec `sudo k3s crictl pull`, puis en faisant de même pour `traefik/whoami` avant les parties suivantes.
- **`--atomic --timeout 60s`** : le rollback automatique a échoué faute de temps (release en `failed`). Réparation par `helm rollback ... --wait --timeout 120s`, puis nouvel essai réussi avec `--timeout 90s`.
- **`kubectl exec ... -- env` impossible** : l'image `traefik/whoami` ne contient aucun binaire (`executable file not found in $PATH`). La valeur de `LOG_LEVEL` a été vérifiée avec `jsonpath` sur le Deployment et le ConfigMap, et `WHOAMI_NAME` avec un `port-forward`.
- **Port local 8080 déjà utilisé** par un Jenkins (`address already in use`) : le `curl` interrogeait Jenkins sans que l'on s'en aperçoive. Solution : `port-forward` sur le port 18080.

[![Port 8080 déjà utilisé](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp15/kustomize-port-8080-conflit.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp15/kustomize-port-8080-conflit.png)

[![exec impossible : image sans binaire](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp15/kustomize-exec-erreur.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp15/kustomize-exec-erreur.png)
- **Chevrons laissés dans les commandes** : `<IP>` et `<tag>` d'un énoncé sont des emplacements à remplacer, ce qui a fait échouer l'entrée `/etc/hosts` et un `crictl pull`.
- **Fichiers de départ absents de la VM** : `chart-starter.zip` et `kustomize-starter.zip` étaient sur Windows, copiés avec `scp` avant extraction.
- **Harbor arrêté** : voir le défi 2.

---

## 9. Liste des captures

[#9-liste-des-captures](#9-liste-des-captures)

| Fichier                   | Contenu                                                              |
| ------------------------- | -------------------------------------------------------------------- |
| `helm-lint-template.png`  | `helm lint` sans erreur, extrait de `helm template` et Ingress       |
| `helm-history.png`        | `helm history` après upgrade, échec et rollback                      |
| `helm-atomic.png`         | Upgrade `--atomic` annulé automatiquement                            |
| `kustomize-envs.png`      | Trois Deployments (dev / staging / prod) avec des replicas différents |
| `kustomize-diff.png`      | `diff` staging / prod                                                |
| `helm-schema.png`         | `helm lint` refusant `replicaCount: "trois"` (défi 1)                |

Captures complémentaires :

| Fichier | Contenu |
| --- | --- |
| `helm-podinfo-pods.png` | Chart public podinfo : 2 pods `Running` |
| `helm-atomic-historique.png` | Premier essai `--atomic` : échec à 60 s, réussite à 90 s |
| `helm-lint.png`, `helm-dry-run-debut.png`, `helm-dry-run-fin.png` | Lint et `--dry-run=server` |
| `helm-install-dev.png`, `helm-upgrade-rev2.png`, `helm-upgrade-rev3-echec.png` | Révisions 1 à 3 |
| `helm-package-0.1.0.png`, `helm-package-0.1.1.png` | Archives du chart |
| `helm-uninstall.png` | Désinstallation de la release |
| `kustomize-apply.png`, `kustomize-configmap-verif.png`, `kustomize-port-forward-ok.png` | Déploiement et vérification du ConfigMap |
| `kustomize-port-8080-conflit.png`, `kustomize-exec-erreur.png` | Difficultés rencontrées |
| `helm-schema-fichiers.png`, `helm-schema-template.png` | Défi 1 : schéma et refus par `helm template` |

---

# TP16 : HTTPS avec cert-manager et IAM avec Keycloak (OIDC)

**Auteur :** Wissal **Date :** 19 novembre 2026 **Environnement :** Ubuntu Server 26.04, K3s v1.36.5+k3s1 (TP14), Helm v3.22.1, cert-manager v1.21.3, Keycloak 26.3.5, oauth2-proxy v7.9.0

Sans nom de domaine public, Let's Encrypt est impossible : une **autorité de certification de lab** est créée avec cert-manager. Keycloak sert de fournisseur d'identité (OpenID Connect) et oauth2-proxy protège l'application `whoami` sans modifier son code.

## Sommaire

1. [Structure du rendu](#1-structure-du-rendu-tp16)
2. [Partie 1 : cert-manager et CA de lab](#2-partie-1--cert-manager-et-ca-de-lab)
3. [Partie 2 : Ingress HTTPS](#3-partie-2--ingress-https)
4. [Partie 3 : déployer Keycloak](#4-partie-3--déployer-keycloak)
5. [Partie 4 : realm, client, rôles et utilisateurs](#5-partie-4--realm-client-rôles-et-utilisateurs)
6. [Partie 5 : oauth2-proxy](#6-partie-5--protéger-lapplication-avec-oauth2-proxy)
7. [Défis](#7-défis-tp16)
8. [Difficultés rencontrées](#8-difficultés-rencontrées-tp16)
9. [Liste des captures](#9-liste-des-captures-tp16)

## 1. Structure du rendu TP16

Les manifests complétés sont dans `tp16/manifests/` et les captures dans `captures/tp16/`. **Aucun secret n'est versé** : ni la clé privée de la CA (`tls.key`), ni le secret du client, ni le mot de passe administrateur, ni les mots de passe des utilisateurs. Les Secrets sont créés en ligne de commande.

```
tp16/manifests/
├── 00-app.yaml
├── 05-coredns-custom.yaml      (IP du nœud : 172.28.79.32)
├── 10-issuers.yaml             (ClusterIssuer ca : secretName: lab-ca)
├── 20-ingress-tls.yaml         (bloc tls, entrée websecure, backend oauth2-proxy)
├── 30-keycloak.yaml
└── 40-oauth2-proxy.yaml        (--allowed-role=developer et admin)
captures/tp16/
```

## 2. Partie 1 : cert-manager et CA de lab

```
helm repo add jetstack https://charts.jetstack.io && helm repo update
helm install cert-manager jetstack/cert-manager -n cert-manager --create-namespace --set crds.enabled=true
kubectl apply -f manifests/10-issuers.yaml
kubectl get clusterissuers
kubectl -n cert-manager get certificate lab-ca
```

Le TODO de `10-issuers.yaml` est complété : l'émetteur `lab-ca-issuer` est de type `ca` et lit le Secret `lab-ca` (`ca.secretName: lab-ca`). Deux émetteurs existent : `selfsigned` (qui sert seulement à créer la CA) et `lab-ca-issuer` (qui signe les certificats des applications).

[![cert-manager : pods Running, CRD installées, release à réparer](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp16/cert-manager-pods.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp16/cert-manager-pods.png)

[![Webhook cert-manager opérationnel (dry-run serveur)](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp16/issuers-dry-run.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp16/issuers-dry-run.png)

[![ClusterIssuers READY True, Certificate lab-ca, dates de la CA, confiance sur la VM](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp16/clusterissuers.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp16/clusterissuers.png)

La CA `Lab DevSecOps CA` est valable un an. Son **certificat public** (`ca.crt`) est exporté et installé comme autorité de confiance sur la VM (`update-ca-certificates` : `1 added`). La clé privée n'est jamais diffusée : quiconque la possède peut émettre des certificats valides pour n'importe quel nom.

## 3. Partie 2 : Ingress HTTPS

`20-ingress-tls.yaml` reçoit un bloc `tls` (hôte `whoami.lab.local`, Secret `whoami-tls`) et l'annotation Traefik `router.entrypoints: websecure` (HTTPS uniquement). L'annotation `cert-manager.io/cluster-issuer: lab-ca-issuer` demande à cert-manager de créer le certificat lui-même.

```
kubectl apply -f manifests/20-ingress-tls.yaml
kubectl -n tp16 get certificate,certificaterequest
curl -v https://whoami.lab.local
```

[![curl : certificat vérifié, émis par Lab DevSecOps CA, HTTP/2 200](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp16/https-curl.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp16/https-curl.png)

[![SAN DNS:whoami.lab.local et validité de 90 jours](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp16/https-san.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp16/https-san.png)

**Que fait cert-manager si on supprime le Secret `whoami-tls` ?** Il détecte l'absence du Secret (`Issuing certificate as Secret does not exist`), génère une nouvelle clé, crée un nouveau `CertificateRequest` (`whoami-tls-2`) et recrée le Secret en quelques secondes. Le renouvellement anticipé est réglé par **`spec.renewBefore`** ; vide ici, le défaut s'applique (un tiers de la durée de vie) : `renewalTime` tombe 30 jours avant l'expiration (durée par défaut de 90 jours).

[![Suppression du Secret : cert-manager le recrée](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp16/https-secret-renew.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp16/https-secret-renew.png)

## 4. Partie 3 : déployer Keycloak

```
kubectl create namespace keycloak
kubectl -n keycloak create secret generic keycloak-admin --from-literal=password="$(openssl rand -base64 18)"
kubectl apply -f manifests/05-coredns-custom.yaml
kubectl -n kube-system rollout restart deploy/coredns
kubectl apply -f manifests/30-keycloak.yaml
kubectl -n keycloak rollout status deploy/keycloak
```

`05-coredns-custom.yaml` fait résoudre `*.lab.local` vers l'IP du nœud **à l'intérieur du cluster** : oauth2-proxy doit joindre Keycloak par le même nom que le navigateur, sinon l'émetteur (`iss`) des jetons ne correspond pas. Keycloak tourne en mode `start-dev` (base H2 en mémoire, un seul Pod) : lab uniquement.

[![Keycloak 26.3.5 Running, Ingress, certificat keycloak-tls READY True](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp16/keycloak-pods.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp16/keycloak-pods.png)

[![https://keycloak.lab.local répond 200 sans -k](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp16/keycloak-curl-200.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp16/keycloak-curl-200.png)

[![Page de connexion Keycloak en HTTPS](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp16/keycloak-login.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp16/keycloak-login.png)

## 5. Partie 4 : realm, client, rôles et utilisateurs

Dans le realm **`lab`** : rôles `user`, `developer`, `admin` ; utilisateurs `alice` (admin), `bob` (developer), `carol` (user) avec email, prénom, nom, **Email verified** activé, et un mot de passe non temporaire. Le client `whoami` est **confidentiel** (flux Standard uniquement), avec l'URI de redirection `https://whoami.lab.local/oauth2/callback` et un mapper **Audience** qui place `whoami` dans le claim `aud`.

[![Realm lab : rôles et utilisateurs](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp16/keycloak-realm.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp16/keycloak-realm.png)

[![Client whoami : URI de redirection et origine web](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp16/keycloak-client-redirect.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp16/keycloak-client-redirect.png)

[![Mapper Audience whoami-audience](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp16/keycloak-client-mapper.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp16/keycloak-client-mapper.png)

[![Rôle direct de bob : developer](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp16/keycloak-role-bob.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp16/keycloak-role-bob.png)

[![Rôle direct de carol : user](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp16/keycloak-role-carol.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp16/keycloak-role-carol.png)

[![Rôle direct d'alice : admin](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp16/keycloak-role-alice.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp16/keycloak-role-alice.png)

### Jeton JWT de `bob`

Le flux password n'est utilisé ici que pour observer le jeton (**Direct access grants** activé temporairement, puis désactivé).

[![Jeton décodé : iss, aud, exp, rôles](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp16/jwt-decoded.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp16/jwt-decoded.png)

- `iss` : `https://keycloak.lab.local/realms/lab` (identique à l'`issuer` de la découverte OIDC) ;
- `aud` : `whoami` (mapper Audience) et `account` ;
- `exp` : timestamp Unix d'expiration (quelques minutes) ;
- `preferred_username` : `bob` ; `realm_access.roles` contient `developer`.

[![Découverte OIDC : issuer et endpoints](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp16/oidc-discovery.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp16/oidc-discovery.png)

## 6. Partie 5 : protéger l'application avec oauth2-proxy

Deux Secrets sont créés en ligne de commande (jamais dans le dépôt) : `oauth2-proxy` (secret du client, secret de cookie) et `lab-ca-public` (certificat **public** de la CA, pour que oauth2-proxy joigne Keycloak en HTTPS). Le TODO de `40-oauth2-proxy.yaml` est complété avec `--allowed-role=developer` et `--allowed-role=admin`, puis l'Ingress `whoami` pointe vers le Service `oauth2-proxy`.

[![oauth2-proxy déployé avec les deux rôles autorisés](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp16/oauth2-deploy.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp16/oauth2-deploy.png)

[![L'Ingress pointe vers oauth2-proxy](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp16/oauth2-ingress.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp16/oauth2-ingress.png)

[![Sans session : 403, page de connexion oauth2-proxy](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp16/oauth2-curl-403.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp16/oauth2-curl-403.png)

[![Page de connexion oauth2-proxy](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp16/oauth2-login.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp16/oauth2-login.png)

### Accès autorisé : `bob` et `alice`

[![bob (developer) et alice (admin) accèdent à whoami](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp16/oauth2-allowed.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp16/oauth2-allowed.png)

L'application reçoit l'identité dans les en-têtes : `X-Forwarded-User`, `X-Forwarded-Email` (`bob@lab.local`, `alice@lab.local`), `X-Forwarded-Preferred-Username` et `X-Forwarded-Groups` (qui contient `role:developer` pour bob, `role:admin` pour alice). Ce sont les en-têtes que oauth2-proxy transmet à l'amont quand il fait office de reverse proxy ; les en-têtes `X-Auth-Request-*` de l'énoncé sont ceux de son mode `auth_request` (réponse à un sous-requête de Traefik). Le jeton d'accès (`X-Forwarded-Access-Token`) et le cookie de session sont **masqués** sur les captures.

### Accès refusé : `carol`

[![carol (rôle user) : 403 Forbidden](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp16/oauth2-403.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp16/oauth2-403.png)

`carol` s'authentifie correctement chez Keycloak, mais n'a ni `developer` ni `admin` : oauth2-proxy journalise `[AuthFailure] Invalid authentication via OAuth2: unauthorized` pour `carol@lab.local` et renvoie 403. C'est la différence entre **authentification** (qui est-ce ?) et **autorisation** (a-t-il le droit ?).

### Déconnexion et SSO

`/oauth2/sign_out` supprime seulement le cookie d'oauth2-proxy, c'est-à-dire la session de l'application. La session de l'utilisateur chez Keycloak reste ouverte : au prochain accès, l'utilisateur est reconnecté sans ressaisir son mot de passe. C'est le principe du **SSO**. Pour tout fermer, il faut aussi se déconnecter de Keycloak, ou configurer une déconnexion unique (`--backend-logout-url`).

## 7. Défis TP16

Non réalisés : middleware Express validant le JWT (JWKS, `iss`, `aud`, `exp`) et émetteur ACME local (step-ca ou Pebble).

## 8. Difficultés rencontrées TP16

- **`helm install cert-manager` expiré** (`failed post-install: timed out`) : le Job `startupapicheck` avait échoué pendant le téléchargement lent des images. Les composants tournaient ; `helm upgrade --wait` a remis la release en `deployed`.
- **Ingress du TP14 sur le même hôte** : `whoami.lab.local` renvoyait `Name: tp14-v3`. L'Ingress du TP14 a été sauvegardé puis supprimé.
- **Image Keycloak coupée** (`connection reset by peer`, `crictl pull` sans message après `timeout`) : téléchargement avec `docker pull` puis `docker save | k3s ctr images import -` (sans fichier intermédiaire, car `/tmp` est en mémoire).
- **Fichier hosts Windows non pris en compte** : ligne ajoutée en PowerShell administrateur, puis `ipconfig /flushdns` ; la CA est importée dans le magasin de confiance Windows.
- **Deux realms `lab`** : un realm au nom contenant une espace (`lab%20` dans l'URL) avait été créé par erreur ; supprimé après vérification avec `jq .realm`.
- **Jeton `null`** : `Client not allowed for direct access grants`, puis `Invalid user credentials`, puis `Account is not fully set up` : flux password à activer, mot de passe à redéfinir (**Temporary** sur Off), actions requises à vider.
- **Emails personnels visibles** sur une capture : remplacés par `…@lab.local`.

[![Deux realms : lab et un doublon mal nommé](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp16/keycloak-realms-doublon.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp16/keycloak-realms-doublon.png)

[![Realm lab : 200, lab%20 : 404 après suppression](https://github.com/wissalelkouk/tp13-floci-terraform/raw/main/captures/tp16/realm-lab-verif.png)](https://github.com/wissalelkouk/tp13-floci-terraform/blob/main/captures/tp16/realm-lab-verif.png)

## 9. Liste des captures TP16

| Fichier | Contenu |
| --- | --- |
| `clusterissuers.png` | ClusterIssuers, Certificate de la CA |
| `https-curl.png` | `curl` : certificat vérifié, émis par la CA de lab |
| `keycloak-realm.png` | Realm `lab` : rôles et utilisateurs |
| `jwt-decoded.png` | Jeton décodé : `iss`, `aud`, `exp`, rôles |
| `oauth2-allowed.png` | Accès autorisé (bob et alice), jeton masqué |
| `oauth2-403.png` | Accès refusé (carol) |
