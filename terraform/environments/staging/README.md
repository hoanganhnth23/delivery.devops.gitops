# Terraform — cụm staging đang chạy

Nguồn sự thật cho node pool của cụm zonal `delivery-cluster` (asia-southeast1-a).
Thư mục `terraform/` gốc mô tả một cụm regional khác, chưa từng apply; không dùng cho staging.

| Quản lý ở đây | Ngoài phạm vi (bước sau) |
|---|---|
| Node pool `core-pool` (e2-standard-4), `data-pool` (c3-standard-4, taint), `elastic-pool` (c3-standard-4, taint); node private | Bản thân cụm GKE (đang tham chiếu bằng data source; import sau) |
| Cloud Router + Cloud NAT `delivery-asia-southeast1-*` cho node private | Pool cũ `staging-pool` (xoá bằng gcloud sau khi pool mới chạy ổn) |

Số node mỗi buổi đổi bằng `scripts/staging-up.sh` / `staging-down.sh` (Terraform bỏ qua `node_count`).

## Chạy

```bash
cd terraform/environments/staging
export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token)   # hoặc gcloud auth application-default login
terraform init
terraform plan    # phải đọc kỹ: không được có "destroy"/"must be replaced" ngoài ý muốn
terraform apply
```

State: `gs://lithe-paratext-506208-s5-tfstate/staging` (bucket có versioning, tạo một lần bằng
`gcloud storage buckets create ... --uniform-bucket-level-access` + `--versioning`).

## Quota (2026-11-02)

`CPUS_ALL_REGIONS = 12`, `C3_CPUS = 8`, `E2_CPUS = 8`, `IN_USE_ADDRESSES = 4` (Kong LB dùng 1, NAT dùng 1).
3 node × 4 vCPU là trần. Thêm node/HPA ra node mới phải xin tăng quota trước.
