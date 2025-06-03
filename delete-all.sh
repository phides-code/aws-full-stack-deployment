#!/bin/bash

# This script deletes all resources created by the project.

echo "=== Deleting CloudFront distribution and related resources ==="

echo "Fetching current CloudFront distribution config..."
aws cloudfront get-distribution-config --id "$CLOUDFRONT_DISTRIBUTION_ID" > config.json

echo "Extracting ETag..."
ETAG=$(jq -r '.ETag' config.json)
echo "ETag: $ETAG"

echo "Disabling CloudFront distribution..."
jq '.DistributionConfig | .Enabled = false' config.json | sponge config.json
aws cloudfront update-distribution --id "$CLOUDFRONT_DISTRIBUTION_ID" --distribution-config file://config.json --if-match "$ETAG"

rm config.json

echo "Waiting for CloudFront distribution to be fully disabled..."
while true; do
    STATUS=$(aws cloudfront get-distribution --id "$CLOUDFRONT_DISTRIBUTION_ID" | jq -r '.Distribution.Status')
    ENABLED=$(aws cloudfront get-distribution --id "$CLOUDFRONT_DISTRIBUTION_ID" | jq -r '.Distribution.DistributionConfig.Enabled')
    echo "Current status: $STATUS, Enabled: $ENABLED"
    if [ "$STATUS" = "Deployed" ] && [ "$ENABLED" = "false" ]; then
        echo "Distribution is now disabled and ready to be deleted."
        break
    fi
    echo "Still waiting... (this may take 15-30 minutes)"
    sleep 5
done

echo "Deleting CloudFront distribution..."
LATEST_ETAG=$(aws cloudfront get-distribution-config --id "$CLOUDFRONT_DISTRIBUTION_ID" | jq -r '.ETag')
aws cloudfront delete-distribution --id "$CLOUDFRONT_DISTRIBUTION_ID" --if-match "$LATEST_ETAG"

echo "Deleting Origin Access Control (OAC)..."
OAC_ETAG=$(aws cloudfront get-origin-access-control --id "$CLOUDFRONT_OAC_ID" | jq -r '.ETag')
aws cloudfront delete-origin-access-control --id "$CLOUDFRONT_OAC_ID" --if-match "$OAC_ETAG"

echo "=== Emptying and deleting S3 bucket ==="
aws s3 rm "s3://$S3_BUCKET_NAME" --recursive
aws s3api delete-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION"

cd "$PROJECT_NAME-frontend" || exit 1

echo "Deleting frontend GitHub repo..."
gh repo delete --yes

echo "=== Deleting backend resources ==="
cd "../$SERVICE_NAME" || exit 1

echo "Deleting backend CloudFormation stack..."
make delete

echo "Deleting backend GitHub repo..."
gh repo delete --yes

cd .. || exit 1

echo "=== Deleting Cognito Identity Pool ==="
aws cognito-identity delete-identity-pool --identity-pool-id "$COGNITO_IDENTITY_POOL_ID"

echo "=== Detaching and deleting IAM policies and role ==="
aws iam detach-role-policy --role-name "$IAM_ROLE_NAME" --policy-arn "$UNAUTH_CREDENTIALS_POLICY_ARN"
aws iam delete-policy --policy-arn "$UNAUTH_CREDENTIALS_POLICY_ARN"
aws iam delete-role-policy --role-name "$IAM_ROLE_NAME" --policy-name "$API_GATEWAY_POLICY_NAME"
aws iam delete-role --role-name "$IAM_ROLE_NAME"

echo "=== All resources deleted ==="

