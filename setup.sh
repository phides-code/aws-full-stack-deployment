#!/bin/bash

echo "=== AWS Full Stack Project Setup ==="

# Check if the user provided one argument
if [ "$#" -ne 1 ]; then
    echo "Usage: setup.sh PROJECT_NAME"
    exit 1
fi

# Assign the argument to a variable
project_name="$1"
echo "Project name: $project_name"

# convert project name to 3 different formats
lowercase_project_name=$(echo "$project_name" | tr '[:upper:]' '[:lower:]')
camel_case_project_name=$(echo "$project_name" | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2)); print}' OFS='')
service_name=$lowercase_project_name-bananas-service
echo "Service name: $service_name"

### setup aws secrets
# Path to AWS credentials and config files
AWS_CREDENTIALS_FILE="$HOME/.aws/credentials"
AWS_CONFIG_FILE="$HOME/.aws/config"

# Check if the files exist
if [ ! -f "$AWS_CREDENTIALS_FILE" ]; then
    echo "AWS credentials file not found: $AWS_CREDENTIALS_FILE"
    exit 1
fi
if [ ! -f "$AWS_CONFIG_FILE" ]; then
    echo "AWS config file not found: $AWS_CONFIG_FILE"
    exit 1
fi

echo "Extracting AWS credentials and region..."
# Extract aws_access_key_id
AWS_ACCESS_KEY_ID=$(grep "aws_access_key_id" "$AWS_CREDENTIALS_FILE" | head -n 1 | cut -d "=" -f 2 | tr -d '[:space:]')

# Extract aws_secret_access_key
AWS_SECRET_ACCESS_KEY=$(grep "aws_secret_access_key" "$AWS_CREDENTIALS_FILE" | head -n 1 | cut -d "=" -f 2 | tr -d '[:space:]')

# Extract default region
AWS_REGION=$(grep "region" "$AWS_CONFIG_FILE" | head -n 1 | cut -d "=" -f 2 | tr -d '[:space:]')

# Check if the aws variables are empty
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    echo "Failed to extract AWS credentials from file."
    exit 1
fi
if [ -z "$AWS_REGION" ]; then
    echo "Failed to extract AWS region from file."
    exit 1
fi

echo "AWS Region: $AWS_REGION"

# Get our AWS account ID
echo "Getting AWS account ID..."
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "AWS Account ID: $AWS_ACCOUNT_ID"

# Create parent folder
if [ ! -d "./$lowercase_project_name" ]; then
    echo "Creating parent folder: $lowercase_project_name-parent"
    mkdir "./$lowercase_project_name-parent"
else
    echo "Folder already exists"
    exit 1
fi

# Move into the parent folder
cd "$lowercase_project_name-parent" || exit

# Setup backend
echo "Cloning backend template repo..."
npx degit phides-code/go-dynamodb-service-template "$service_name"

# Move into the service folder
cd "$lowercase_project_name-bananas-service" || exit

echo "Replacing template variables in backend files..."
find . -type f -exec sed -i "s/Appname/$camel_case_project_name/g" {} +
find . -type f -exec sed -i "s/appname/$lowercase_project_name/g" {} +
find . -type f -exec sed -i "s/us-east-1/$AWS_REGION/g" {} +

# create GitHub repo
echo "Setting up GitHub repository..."
# display a mini menu to prompt for GitHub repo visibility
visibility_options=("public" "private")
echo ""
PS3="Please select repo visibility: Make this GitHub repo Public (1) or Private (2)? "
select option in "${visibility_options[@]}"; do
    case $option in
        "public")
            selected_visibility="public"
            break
        ;;
        "private")
            selected_visibility="private"
            break
        ;;
        *)
            echo "Invalid option. Please select 1 (public) or 2 (private)."
        ;;
    esac
done

# create remote repo on github
echo "Initializing git and creating GitHub repo ($selected_visibility)..."
git init
gh repo create  --source=. --"$selected_visibility"

# setup AWS secrets in GitHub
echo "Adding AWS secrets to GitHub repo..."
gh secret set AWS_ACCESS_KEY_ID --body "$AWS_ACCESS_KEY_ID"
gh secret set AWS_SECRET_ACCESS_KEY --body "$AWS_SECRET_ACCESS_KEY"

# commit and push changes
echo "Committing and pushing initial code to GitHub..."
git add .
git commit -m "initial commit"
git push origin main

# watch the progress of the GitHub Actions workflow
echo "Watching GitHub Actions workflow..."
sleep 5
gh run watch

# get the api gateway id and the url for the service
echo "Fetching API Gateway ID..."
api_gateway_id=$(aws apigateway get-rest-apis | jq -r --arg service "$service_name" '.items[] | select(.name == $service) | .id')
service_url="https://$api_gateway_id.execute-api.$AWS_REGION.amazonaws.com/Prod/bananas"
echo "Service URL: $service_url"

# Create identity pool
echo "=== Creating Cognito Identity Pool ==="
identity_pool_id=$(aws cognito-identity create-identity-pool \
    --identity-pool-name "$camel_case_project_name"IdentityPool \
    --allow-unauthenticated-identities \
    --no-allow-classic-flow | jq -r '.IdentityPoolId')
echo "Created Cognito Identity Pool with ID: $identity_pool_id"

# Create unauthenticated trust policy
echo "=== Preparing unauthenticated trust policy JSON ==="
cp ../../json-files/unauth-trust-policy.json .
sed -i "s/IDENTITY_POOL_ID/$identity_pool_id/g" unauth-trust-policy.json
echo "Updated unauth-trust-policy.json with Identity Pool ID."

# Attach the unauthenticated trust policy to a new role
iam_role="$camel_case_project_name"IAMRole
echo "=== Creating IAM role for unauthenticated Cognito access: $iam_role ==="
role_create_response=$(aws iam create-role \
    --role-name "$iam_role" \
    --assume-role-policy-document file://unauth-trust-policy.json)
role_arn=$(echo "$role_create_response" | jq -r '.Role.Arn')
echo "Created IAM Role: $iam_role"
echo "Role ARN: $role_arn"

# Link the role to the identity pool
echo "=== Linking IAM role to Cognito Identity Pool ==="
aws cognito-identity set-identity-pool-roles \
    --identity-pool-id "$identity_pool_id" \
    --roles unauthenticated="$role_arn"
echo "Linked $iam_role to Identity Pool $identity_pool_id"

# Create unauth credentials policy
echo "=== Creating unauthenticated credentials policy JSON ==="
cp ../../json-files/unauth-credentials-policy.json .
unauth_creds_policy="$camel_case_project_name"GetCredentialsPolicy

echo "=== Creating managed IAM policy for unauthenticated Cognito credentials: $unauth_creds_policy ==="
policy_create_response=$(aws iam create-policy \
    --policy-name "$unauth_creds_policy" \
    --policy-document file://unauth-credentials-policy.json)
policy_arn=$(echo "$policy_create_response" | jq -r '.Policy.Arn')
echo "Created IAM Policy: $unauth_creds_policy"
echo "Policy ARN: $policy_arn"

# Attach the unauthenticated policy to the role
echo "=== Attaching credentials policy to IAM role ==="
aws iam attach-role-policy \
    --role-name "$iam_role" \
    --policy-arn "$policy_arn"
echo "Attached policy $unauth_creds_policy ($policy_arn) to role $iam_role"

# Create and attach policy for api gateway access
echo "=== Creating and attaching policy for API Gateway access ==="
api_gateway_policy_name="$camel_case_project_name"APIGatewayPolicy
cp ../../json-files/api-gateway-policy.json .
sed -i "s/API_GATEWAY_ID/$api_gateway_id/g" api-gateway-policy.json
sed -i "s/AWS_ACCOUNT_ID/$AWS_ACCOUNT_ID/g" api-gateway-policy.json

aws iam put-role-policy \
    --role-name "$iam_role" \
    --policy-name "$api_gateway_policy_name" \
    --policy-document file://api-gateway-policy.json

# Remove the temporary files
echo "Cleaning up temporary policy files..."
rm unauth-trust-policy.json
rm unauth-credentials-policy.json
rm api-gateway-policy.json

###
### FRONTEND SETUP
###
# Move to the parent folder
cd .. || exit
# Clone the frontend template repo
echo "Cloning frontend template repo..."
npx degit phides-code/react-s3-template-app "$lowercase_project_name"-frontend

# Move into the frontend folder
cd "$lowercase_project_name"-frontend || exit

# Replace appname in frontend files
echo "Replacing template variables in frontend files..."
find . -type f -exec sed -i "s/appname/$lowercase_project_name/g" {} +

### Generate random ID for CloudFront CallerReference and S3 bucket name
random_id=$(head /dev/urandom | md5sum | head -c 32)
short_id=${random_id:0:8}

### setup new s3 bucket
# Combine project name and short ID
bucket_name="${lowercase_project_name}-${short_id}"

# Create the S3 bucket
echo "=== Creating S3 bucket for frontend ==="
aws s3 mb "s3://${bucket_name}"
echo "Created S3 bucket: ${bucket_name}"

### setup CloudFront
# copy CloudFront distribution config, S3 policy, and OAC config
cp ../../json-files/my-dist-config.json .
cp ../../json-files/s3-policy.json .
cp ../../json-files/oac-config.json .

# replace placeholder names in json files
sed -i "s|BUCKET_NAME|$bucket_name|" my-dist-config.json
sed -i "s|CALLER_REFERENCE|$random_id|" my-dist-config.json
sed -i "s|AWS_REGION|$AWS_REGION|" my-dist-config.json
sed -i "s|BUCKET_NAME|$bucket_name|" s3-policy.json
sed -i "s|BUCKET_NAME|$bucket_name|" oac-config.json

# create OAC, capture the OAC id and insert in my-dist-config.json
echo "=== Creating CloudFront Origin Access Control (OAC) ==="
oac_create_response=$(aws cloudfront create-origin-access-control --origin-access-control-config file://oac-config.json)
oac_id=$(echo "$oac_create_response" | jq -r '.OriginAccessControl.Id')
echo "Created OAC with ID: $oac_id"
sed -i "s|OAC_ID|$oac_id|" my-dist-config.json

# create CloudFront distribution and capture the ARN
echo "=== Creating CloudFront distribution ==="
dist_create_response=$(aws cloudfront create-distribution --distribution-config file://my-dist-config.json)
arn=$(echo "$dist_create_response" | jq -r '.Distribution.ARN')
dist_domain=$(echo "$dist_create_response" | jq -r '.Distribution.DomainName')
dist_domain=https://$dist_domain
distribution_id=$(echo "$dist_create_response" | jq -r '.Distribution.Id')
echo "Created CloudFront distribution: ${distribution_id}"
echo "Distribution ARN: $arn"

# update s3-policy.json with ARN
echo "Updating S3 bucket policy with CloudFront distribution ARN..."
sed -i "s|SOURCE_ARN|$arn|" s3-policy.json

# update S3 bucket policy
echo "Applying S3 bucket policy..."
aws s3api put-bucket-policy --bucket "$bucket_name" --policy file://s3-policy.json

# remove json files
echo "Cleaning up CloudFront and S3 policy files..."
rm my-dist-config.json
rm s3-policy.json
rm oac-config.json

# Create GitHub repo for frontend
echo "=== Creating GitHub repo for frontend ==="
git init
gh repo create "$lowercase_project_name"-frontend --source=. --"$selected_visibility"

# Setup AWS secrets in GitHub for frontend
echo "Adding AWS and deployment secrets to GitHub repo for frontend..."
gh secret set AWS_ACCESS_KEY_ID --body "$AWS_ACCESS_KEY_ID"
gh secret set AWS_SECRET_ACCESS_KEY --body "$AWS_SECRET_ACCESS_KEY"
gh secret set AWS_REGION --body "$AWS_REGION"
gh secret set AWS_S3_BUCKET --body "$bucket_name"
gh secret set AWS_DISTRIBUTION --body "$distribution_id"
gh secret set BANANAS_SERVICE_URL --body "$service_url"
gh secret set IDENTITY_POOL_ID --body "$identity_pool_id"

# Create local .env file for frontend
echo "Creating local .env file for frontend..."
cat <<EOF > .env
VITE_BANANAS_SERVICE_URL=$service_url
VITE_IDENTITY_POOL_ID=$identity_pool_id
VITE_AWS_REGION=$AWS_REGION
EOF

### initial commit:
echo "Committing and pushing frontend code to GitHub..."
git add .
git commit -m "initial commit"
git push origin main

# go back to the backend directory
cd ../"$service_name" || exit

# setup distribution url as origin in backend
echo "Setting CloudFront distribution as frontend origin in backend..."
sed -i "s|FRONTEND_URL|$dist_domain|g" ./*

# commit and push changes to backend repo
git add .
git commit -m "Set CloudFront distribution as frontend origin"
git push origin main

# watch the progress of the GitHub Actions workflow
echo "Watching GitHub Actions workflow..."
sleep 5
gh run watch

### wrap up message
echo ""
echo "Please allow a few moments for the GitHub Actions workflow to complete."
echo "View the progress by running:"
echo ""
echo "cd $lowercase_project_name-parent/$lowercase_project_name-frontend"
echo "gh run watch"
echo ""

# go back to the parent directory
cd .. || exit

echo "==== Summary of created resources and variables ===="
echo "Project name: $project_name"
echo "Service name: $service_name"
echo "API Gateway ID: $api_gateway_id"
echo "Service URL: $service_url"
echo "Cognito Identity Pool ID: $identity_pool_id"
echo "IAM Role Name: $iam_role"
echo "IAM Role ARN: $role_arn"
echo "Unauthenticated Credentials Policy Name: $unauth_creds_policy"
echo "Unauthenticated Credentials Policy ARN: $policy_arn"
echo "API Gateway Policy Name: $api_gateway_policy_name"
echo "S3 Bucket Name: $bucket_name"
echo "CloudFront Distribution ID: $distribution_id"
echo "CloudFront OAC ID: $oac_id"
echo "CloudFront Domain: $dist_domain"
echo ""
echo "All variables above can be used for further automation or manual configuration."

# copy delete-all.sh from the parent directory
echo "Preparing delete-all.sh for future cleanup automation..."
cp ../delete-all.sh .
chmod +x delete-all.sh

# Prepare variable declarations for delete-all.sh
delete_vars=$(cat <<EOF
#!/bin/bash
PROJECT_NAME="$project_name"
SERVICE_NAME="$service_name"
AWS_REGION="$AWS_REGION"
COGNITO_IDENTITY_POOL_ID="$identity_pool_id"
IAM_ROLE_NAME="$iam_role"
UNAUTH_CREDENTIALS_POLICY_ARN="$policy_arn"
API_GATEWAY_POLICY_NAME="$api_gateway_policy_name"
S3_BUCKET_NAME="$bucket_name"
CLOUDFRONT_DISTRIBUTION_ID="$distribution_id"
CLOUDFRONT_OAC_ID="$oac_id"
EOF
)

# Prepend variables to delete-all.sh, keeping the rest of the script
if [ -f delete-all.sh ]; then
    tmpfile=$(mktemp)
    echo "$delete_vars" > "$tmpfile"
    cat delete-all.sh >> "$tmpfile"
    mv "$tmpfile" delete-all.sh
else
    echo "$delete_vars" > delete-all.sh
fi

echo ""
echo "All resource variables have been prepended to delete-all.sh for future cleanup automation."
