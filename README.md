# EKS Handson環境構築

このリポジトリはEKS初学者向けのハンズオン環境をTerraformで構築するためのコードです。

## 前提条件

- AWSアカウント（適切な権限を持つ）
- AWS CLI（設定済み）
- Terraform v1.5以上
- kubectl
- Helm

## 構築されるリソース

- **VPC**: ハンズオン専用VPC（10.0.0.0/16）
- **Subnet**: パブリック×2、プライベート×2（異なるAZ）
- **EKSクラスター**: Kubernetes v1.28
- **Karpenter**: ワーカーノード自動管理
- **ECR**: コンテナイメージリポジトリ
- **IAM**: 各種サービス用ロール

## 実行手順

⚠️ **重要**: Terraformの動的値依存エラーを回避するため、段階的に適用します。

### フェーズ1: 基盤リソース作成

#### 1. 初期化
```bash
terraform init
```

#### 2. プラン確認
```bash
terraform plan
```

#### 3. 基盤リソース作成（VPC, EKS, ECR）
```bash
terraform apply
```

### フェーズ2: Karpenter有効化

#### 4. Karpenterモジュールを有効化
`main.tf`でコメントアウトしているKarpenterとIAMモジュールを有効化:

```hcl
# main.tfで以下の部分のコメントを外す
module "karpenter" {
  source = "./modules/karpenter"
  
  project_name = var.project_name
  cluster_name = var.cluster_name
  cluster_endpoint = module.eks.cluster_endpoint
  cluster_oidc_issuer_url = module.eks.cluster_oidc_issuer_url
  node_security_group_id = module.eks.node_security_group_id
  common_tags = var.common_tags
  
  depends_on = [module.eks]
}

module "iam" {
  source = "./modules/iam"
  
  project_name = var.project_name
  cluster_name = var.cluster_name
  cluster_oidc_issuer_url = module.eks.cluster_oidc_issuer_url
  common_tags = var.common_tags
  
  depends_on = [module.eks]
}
```

#### 5. Karpenterリソース作成
```bash
terraform apply
```

### フェーズ3: Kubernetes設定

#### 6. kubeconfigの更新
```bash
aws eks update-kubeconfig --name eks-handson-cluster --region ap-northeast-1
```

#### 7. Karpenterのデプロイ
```bash
# Helm repositoryの追加
helm repo add karpenter https://charts.karpenter.sh/
helm repo update

# Karpenterのインストール
helm install karpenter karpenter/karpenter \
  --version "v0.31.0" \
  --namespace karpenter \
  --create-namespace \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$(terraform output -raw karpenter_node_instance_profile_name) \
  --set settings.aws.clusterName=eks-handson-cluster \
  --set settings.aws.defaultInstanceProfile=$(terraform output -raw karpenter_node_instance_profile_name) \
  --set settings.aws.interruptionQueueName=$(terraform output -raw karpenter_queue_name) \
  --wait
```

#### 8. NodePoolとEC2NodeClassの作成

`karpenter-nodepool.yaml`を作成:
```yaml
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["t3.medium", "t3.large"]
      nodeClassRef:
        apiVersion: karpenter.k8s.aws/v1beta1
        kind: EC2NodeClass
        name: default
  limits:
    cpu: 1000
  disruption:
    consolidationPolicy: WhenUnderutilized
    consolidateAfter: 30s
---
apiVersion: karpenter.k8s.aws/v1beta1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: AL2
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "eks-handson-cluster"
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "eks-handson-cluster"
  instanceStorePolicy: NVME
  userData: |
    #!/bin/bash
    /etc/eks/bootstrap.sh eks-handson-cluster
    echo 'vm.max_map_count=262144' >> /etc/sysctl.conf
```

NodePoolを適用:
```bash
kubectl apply -f karpenter-nodepool.yaml
```

#### 9. 動作確認用Podのデプロイ
```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sample-app
spec:
  replicas: 3
  selector:
    matchLabels:
      app: sample-app
  template:
    metadata:
      labels:
        app: sample-app
    spec:
      containers:
      - name: nginx
        image: nginx:latest
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
EOF
```

#### 10. Karpenterの動作確認
```bash
# ノードの確認
kubectl get nodes

# Podの確認
kubectl get pods

# Karpenter logの確認
kubectl logs -f -n karpenter deployment/karpenter
```

## リソース削除

```bash
# Kubernetesリソースの削除
kubectl delete deployment sample-app
kubectl delete -f karpenter-nodepool.yaml
helm uninstall karpenter -n karpenter

# Terraformリソースの削除
terraform destroy
```

## 注意事項

- リソース作成には約15-20分かかります
- 不要時は必ずリソースを削除してください（コスト削減のため）
- 全リソースに`User: reiko.sakaguchi`タグが付与されます

## トラブルシューティング

### Karpenterが動作しない場合
1. IAMロールの権限を確認
2. SecurityGroupの設定を確認
3. SubnetのTagsを確認

### Nodeが起動しない場合
1. EC2NodeClassの設定を確認
2. InstanceProfileの設定を確認
3. Karpenter logsでエラーを確認

## 想定コスト

- EKS制御プレーン: $0.10/時間
- EC2インスタンス（Karpenter管理）: 約$0.04-0.08/時間（スポット使用時）
- NATゲートウェイ: $0.045/時間
- 月額想定: 約$100-150（使用時間による）

## 備考
- 参考: https://github.com/aws-ia/terraform-aws-eks-blueprints/tree/main/patterns/karpenter-mng
- local.nameでtf実行時のcurrent directoryを参照しているため、ex-terraformのようなクラスタ名になってしまう
- `aws eks update-kubeconfig --name {クラスター名} --region ap-northeast-1`

## 構築手順

```
# vpc
terraform apply -target=module.vpc

# eks
terraform apply -target=module.eks

# karpenter
terraform apply

# NodePoolとEC2NodeClassの作成
kubectl apply --server-side -f karpenter.yaml

# argocdデプロイ
terraform apply

# adonの適用
kubectl apply --server-side -f bootstrap/addons.yaml

# リクエスト情報の確認
echo "ArgoCD Password: $(kubectl get secrets argocd-initial-admin-secret -n argocd --template="{{index .data.password | base64decode}}")"
echo "ArgoCD URL: https://$(kubectl get svc -n argocd argo-cd-argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"

# アプリケーションのデプロイ
kubectl apply --server-side -f bootstrap/workloads.yaml
```

一時的なスケールイン
```
# ゲーム
kubectl delete applicationset workloads -n argocd
kubectl delete application workloads -n argocd

# karpenter
kubectl delete nodepool default
kubectl delete ec2nodeclass default
```
