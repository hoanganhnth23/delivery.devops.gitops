# Kong API Gateway - Local Development

Thư mục này cấu hình Kong Gateway chạy ở môi trường **Local** (DB-less mode), phục vụ kiểm thử định tuyến và plugin trước khi triển khai lên GKE Kubernetes.

---

## 1. Yêu Cầu
- Docker / Docker Desktop đang cài đặt trên máy.

---

## 2. Các Lệnh Điều Khiển

```bash
# 1. Khởi động Kong Gateway
./start.sh

# 2. Sửa file kong.yml xong, nạp lại cấu hình tức thì (không cần restart container)
./reload.sh

# 3. Dừng container
./stop.sh
```

---

## 3. Cổng Dịch Vụ
- **Proxy HTTP:** `http://localhost:8000` (Mobile App / Web Portal gọi qua cổng này)
- **Admin API:** `http://localhost:8001` (Kiểm tra status, routes, plugins)
- **Kong Manager UI:** `http://localhost:8002` (Giao diện web trực quan của Kong)

---

## 4. Danh Sách Routes Đã Cấu Hình
- `/api/auth/*` & `/.well-known/jwks.json` -> `host.docker.internal:8081` (Auth Service)
- `/api/users/*` -> `host.docker.internal:8082` (User Service)
- `/api/restaurants/*` & `/api/menus/*` -> `host.docker.internal:8083` (Restaurant Service)
- `/api/orders/*` -> `host.docker.internal:8084` (Order Service)
- `/api/deliveries/*` -> `host.docker.internal:8085` (Delivery Service)
- `/api/search/*` -> `host.docker.internal:8086` (Search Service)
- `/api/promotions/*` & `/api/vouchers/*` -> `host.docker.internal:8087` (Promotion Service)
- `/api/notifications/*` -> `host.docker.internal:8088` (Notification Service)
- `/api/shippers/*` -> `host.docker.internal:8089` (Shipper Service)
- `/api/settlement/*` & `/api/payments/*` -> `host.docker.internal:8090` (Settlement Service)
- `/bff/*` -> `host.docker.internal:8091` (Web BFF)
- `/api/match/*` -> `host.docker.internal:8092` (Match Service)
- `/api/tracking/*` & `/ws/tracking` -> `host.docker.internal:8093` (Tracking Service HTTP & WebSocket)
- `/api/analytics/*` -> `host.docker.internal:8097` (Analytics Service)
- `/api/simulator/*` -> `host.docker.internal:8100` (Simulator Service)
