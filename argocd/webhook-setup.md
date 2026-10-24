# 🔔 Cấu hình Webhook ArgoCD trên GKE

Mặc định, ArgoCD sẽ thăm dò (poll) Git repository mỗi **3 phút**.  
Để cụm GKE **nhận thay đổi và deploy ngay lập tức (sub-second)** sau khi CI/CD push image tag mới, chúng ta cấu hình GitHub Webhook.

---

### Bước 1: Lấy URL công khai của ArgoCD Server

Chạy lệnh:
```bash
kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```
Giả sử IP trả về là `34.123.45.67`.  
URL webhook của bạn sẽ là:
```
https://34.123.45.67/api/webhook
```

---

### Bước 2: Tạo Webhook Secret trong ArgoCD

Tạo một chuỗi bí mật ngẫu nhiên (ví dụ `my-argocd-secret-token`):

```bash
kubectl edit secret argocd-secret -n argocd
```
Thêm hoặc cập nhật khóa `webhook.github.secret`:
```yaml
stringData:
  webhook.github.secret: "my-argocd-secret-token"
```

---

### Bước 3: Đăng ký Webhook trên GitHub (`gitops-cd`)

1. Vào repo GitHub: **`https://github.com/hoanganhnth23/delivery.devops.gitops/settings/hooks`**.
2. Bấm **Add webhook**.
3. Điền các thông số:
   - **Payload URL**: `https://<IP_HOẶC_DOMAIN_ARGOCD>/api/webhook`
   - **Content type**: `application/json`
   - **Secret**: `my-argocd-secret-token` (khớp với secret ở Bước 2)
   - **Which events would you like to trigger this webhook?**: Chọn `Just the push event`.
4. Bấm **Add webhook**.

---

### Kết quả:
Mỗi khi có commit cập nhật image tag vào `gitops-cd`:
GitHub sẽ gửi tín hiệu webhook đến ArgoCD trên GKE → ArgoCD kích hoạt đồng bộ (Sync) ngay lập tức → Kubernetes tự động pull image mới và Rolling Update pod!
