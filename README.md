# AWS Full-Stack Deployment Template

This project provides a set of scripts and configuration files to automate the deployment and teardown of a full-stack application on AWS. It includes example IAM policies, API Gateway, S3, and CloudFront configurations, as well as a backend with a default database table, making it easy to bootstrap a secure and scalable cloud environment.

## Features

-   Automated setup and teardown scripts
-   Example IAM and trust policies
-   API Gateway and S3 configuration templates
-   CloudFront OAC (Origin Access Control) example
-   Backend with a default database table named `Bananas` (can be renamed/customized)
-   Easy customization via JSON config files

## Directory Structure

```
├── delete-all.sh                # Script to delete all deployed AWS resources
├── setup.sh                     # Script to set up all AWS resources
├── json-files/                  # Directory containing JSON configuration files
│   ├── api-gateway-policy.json
│   ├── my-dist-config.json
│   ├── oac-config.json
│   ├── s3-policy.json
│   ├── unauth-credentials-policy.json
│   └── unauth-trust-policy.json
└── README.md                    # Project documentation
```

## Prerequisites

-   [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) configured with appropriate credentials
-   Bash shell (Linux or macOS recommended)
-   jq (for JSON processing, if used in scripts)
-   [git](https://git-scm.com/) (for version control and repository setup)
-   [GitHub CLI (gh)](https://cli.github.com/) (for repository creation and deployment automation)

## Setup Instructions

1. Clone this repository:
    ```bash
    git clone <your-repo-url>
    cd aws-full-stack-deployment
    ```
2. Review and customize the JSON files in `json-files/` as needed for your environment.
3. Run the setup script with your desired project name (required):
    ```bash
    ./setup.sh <project-name>
    ```
    Replace `<project-name>` with a unique name for your deployment. This name will be used to namespace your AWS resources.

## Usage

-   The setup script will provision all necessary AWS resources as defined in the JSON files, using the project name you provide.
-   The backend includes a default database table named `Bananas`. You can rename or customize this table as needed in your configuration.
-   Modify the JSON files to adjust policies, permissions, or resource configurations.

## Cleanup

To remove all deployed resources, run:

```bash
./delete-all.sh
```

## License

This project is provided as-is for educational and demonstration purposes. Please review and adapt all scripts and policies for your production needs.
