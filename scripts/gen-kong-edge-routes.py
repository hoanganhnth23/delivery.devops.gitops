#!/usr/bin/env python3
"""Sinh danh sách route cửa vào (Kong) từ GatewayRouteConfig.java của api-gateway cũ.

Kong thay hẳn Spring api-gateway, nên allowlist (path + method) phải giữ y hệt: chỉ API công
khai ra internet, API nội bộ không có route. Mỗi (route, method) được xếp vào đúng loại
rate-limit như GatewayRateLimitFilter (public_auth, user_registration, public_catalog,
authenticated_read, mutation, websocket_connection).

  python3 scripts/gen-kong-edge-routes.py <GatewayRouteConfig.java> > helm/charts/kong-gateway/files/edge-routes.yaml
  python3 scripts/gen-kong-edge-routes.py <GatewayRouteConfig.java> --check   # so với file đã sinh

Route nằm sau cờ (payment, livestream) và simulator (staging không chạy) bị bỏ qua có chủ đích.
"""
import re
import sys

# Biến uri trong Java -> tên upstream trong values (edgeUpstreams).
URI_VARS = {
    'authServiceUri': 'auth', 'webBffServiceUri': 'webBff', 'userServiceUri': 'user',
    'restaurantServiceUri': 'restaurant', 'orderServiceUri': 'order', 'deliveryServiceUri': 'delivery',
    'searchServiceUri': 'search', 'shipperServiceUri': 'shipper', 'notificationServiceUri': 'notification',
    'trackingServiceUri': 'tracking', 'trackingServiceWsUri': 'tracking', 'settlementServiceUri': 'settlement',
    'promotionServiceUri': 'promotion', 'analyticsServiceUri': 'analytics', 'flashsaleServiceUri': 'flashsale',
}
SKIPPED_UPSTREAMS = {'simulatorServiceUri', 'livestreamServiceUri'}
ALL_METHODS = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS']

PUBLIC_AUTH_POST = {
    '/api/auth/login', '/api/auth/register', '/api/auth/social-login', '/api/auth/refresh-token',
    '/api/auth/logout', '/api/auth/forgot-password', '/api/auth/reset-password',
    '/api/auth/email-verification/request', '/api/auth/email-verification/confirm',
}
PUBLIC_CATALOG_EXACT = {'/api/search/restaurants', '/api/search/dishes', '/api/restaurants',
                        '/api/restaurants/page', '/api/restaurants/search'}


def spring_to_regex(path):
    """Mẫu path Spring -> regex Kong (neo đầu/cuối, khớp chính xác như Spring)."""
    out, i = '', 0
    while i < len(path):
        if path.startswith('/**', i):
            out += '(/.*)?'
            i += 3
        elif path[i] == '{':
            j, depth = i, 0
            while True:
                depth += {'{': 1, '}': -1}.get(path[j], 0)
                if depth == 0:
                    break
                j += 1
            inner = path[i + 1:j]
            out += '(' + inner.split(':', 1)[1] + ')' if ':' in inner else '([^/]+)'
            i = j + 1
        else:
            out += re.escape(path[i]) if path[i] in '.+()[]^$' else path[i]
            i += 1
    return '^' + out + '$'


def category(path, method):
    """Giống GatewayRateLimitFilter.policyFor; path ở dạng mẫu Spring."""
    sample = re.sub(r'\{[^}:]+:[^}]*\}', '1', path)
    sample = re.sub(r'\{[^}]+\}', 'x', sample)
    if path == '/ws/shipper-locations':
        return 'websocket_connection'
    if (method == 'GET' and re.fullmatch(r'/api/auth/registrations/[^/]+', sample)) or \
            (method == 'POST' and sample in PUBLIC_AUTH_POST):
        return 'public_auth'
    if method == 'POST' and sample == '/api/users/registrations':
        return 'user_registration'
    if method == 'GET' and (sample in PUBLIC_CATALOG_EXACT
                            or re.fullmatch(r'/api/restaurants/[0-9]+(?:/ratings)?', sample)
                            or re.fullmatch(r'/api/restaurants/[0-9]+/ratings/page', sample)
                            or re.fullmatch(r'/api/menu-items/restaurant/[0-9]+(?:/(?:available/)?page|/available)?', sample)):
        return 'public_catalog'
    if method in ('GET', 'HEAD', 'OPTIONS'):
        return 'authenticated_read'
    return 'mutation'


def parse_routes(java):
    # Bỏ các khối sau cờ: chỉ lấy phần chuỗi routes chính (trước "if (paymentClientApiEnabled)").
    main = java.split('if (paymentClientApiEnabled)')[0]
    routes = []
    for m in re.finditer(r'\.route\("([^"]+)",\s*r\s*->\s*r\s*(.*?)\.uri\((\w+)\)\)', main, re.S):
        rid, body, uri = m.group(1), m.group(2), m.group(3)
        if uri in SKIPPED_UPSTREAMS:
            continue
        if uri not in URI_VARS:
            sys.exit(f'Không biết upstream cho {rid}: {uri}')
        if '.filters(' in body:
            sys.exit(f'Route {rid} có filter, cần chuyển tay: {body}')
        paths = re.findall(r'"([^"]+)"', re.search(r'\.path\((.*?)\)\s*(?:\.and\(\)|$)', body, re.S).group(1))
        mm = re.search(r'\.method\(([^)]*)\)', body)
        methods = re.findall(r'HttpMethod\.(\w+)', mm.group(1)) if mm else ALL_METHODS
        routes.append({'id': rid, 'upstream': URI_VARS[uri], 'paths': paths, 'methods': methods})
    return routes


def build(routes):
    """Tách mỗi route theo loại rate-limit -> các nhóm (id, upstream, category, methods, regex paths)."""
    groups = {}
    for r in routes:
        for p in r['paths']:
            for meth in r['methods']:
                cat = category(p, meth)
                g = groups.setdefault((r['id'], cat), {'upstream': r['upstream'], 'methods': [], 'paths': []})
                if meth not in g['methods']:
                    g['methods'].append(meth)
                rx = spring_to_regex(p)
                if rx not in g['paths']:
                    g['paths'].append(rx)
    # Một nhóm gộp nhiều path x method: chỉ hợp lệ khi mọi tổ hợp đều cùng loại (kiểm tra lại).
    out = []
    for (rid, cat), g in groups.items():
        out.append({'name': f'{rid}-{cat}'.replace('_', '-')[:63].rstrip('-'), 'upstream': g['upstream'],
                    'rateLimit': cat, 'methods': g['methods'],
                    'websocket': cat == 'websocket_connection', 'paths': g['paths']})
    return out


def pairs_from_java(routes):
    return {(meth, spring_to_regex(p), category(p, meth)) for r in routes for p in r['paths'] for meth in r['methods']}


def pairs_from_groups(groups):
    return {(meth, p, g['rateLimit']) for g in groups for p in g['paths'] for meth in g['methods']}


def to_yaml(groups):
    lines = ['# SINH TỰ ĐỘNG bởi scripts/gen-kong-edge-routes.py từ GatewayRouteConfig.java. Không sửa tay.',
             'routes:']
    for g in groups:
        lines.append(f"  - name: {g['name']}")
        lines.append(f"    upstream: {g['upstream']}")
        lines.append(f"    rateLimit: {g['rateLimit']}")
        lines.append(f"    websocket: {str(g['websocket']).lower()}")
        lines.append('    methods: [' + ', '.join(g['methods']) + ']')
        lines.append('    paths:')
        for p in g['paths']:
            lines.append(f"      - '{p}'")
    return '\n'.join(lines) + '\n'


def main():
    java = open(sys.argv[1]).read()
    routes = parse_routes(java)
    groups = build(routes)
    # Một nhóm có thể chứa path A (catalog) và path B (read) cùng method -> sai loại. Kiểm tra:
    if pairs_from_groups(groups) != pairs_from_java(routes):
        sys.exit('Gộp nhóm làm sai loại rate-limit; cần tách thêm.')
    if '--check' in sys.argv:
        import os
        path = os.path.join(os.path.dirname(__file__), '..', 'helm/charts/kong-gateway/files/edge-routes.yaml')
        if open(path).read() != to_yaml(groups):
            sys.exit('edge-routes.yaml lệch so với GatewayRouteConfig.java: chạy lại script.')
        print(f'OK: {len(routes)} route Java = {len(groups)} nhóm Kong, {len(pairs_from_java(routes))} cặp (method, path).')
        return
    sys.stdout.write(to_yaml(groups))


if __name__ == '__main__':
    main()
