# Services in the local E2E stack and the delivery.core.* repo each is built from.
E2E_SERVICES="api-gateway web-bff auth user restaurant order delivery dispatch match tracking routing shipper settlement notification"

service_repo() {
  case "$1" in
    web-bff) echo web-bff ;;
    api-gateway) echo api-gateway ;;
    *) echo "$1-service" ;;
  esac
}
