#!/bin/bash
# Shared container runtime detection and readiness helpers.

detect_installed_runtime() {
    local has_orbstack=0
    local has_docker_desktop=0

    if [[ -d "/Applications/OrbStack.app" ]] || command -v orbstack &>/dev/null; then
        has_orbstack=1
    fi
    if [[ -d "/Applications/Docker.app" ]]; then
        has_docker_desktop=1
    fi

    if [[ $has_orbstack -eq 1 && $has_docker_desktop -eq 1 ]]; then
        echo "OrbStack or Docker Desktop"
    elif [[ $has_orbstack -eq 1 ]]; then
        echo "OrbStack"
    elif [[ $has_docker_desktop -eq 1 ]]; then
        echo "Docker Desktop"
    else
        echo "none"
    fi
}

detect_running_runtime() {
    local os_name
    os_name=$(docker info --format '{{.OperatingSystem}}' 2>/dev/null || true)
    if [[ "$os_name" == *"OrbStack"* ]]; then
        echo "OrbStack"
    elif [[ "$os_name" == *"Docker Desktop"* ]]; then
        echo "Docker Desktop"
    else
        echo "Docker"
    fi
}

wait_for_service() {
    local name="$1"
    local url="$2"
    local max_attempts="${3:-45}"
    local attempt=0
    local status

    while [[ $attempt -lt $max_attempts ]]; do
        status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "$url" 2>/dev/null || true)
        if [[ "$status" =~ ^(200|301|302|401|403)$ ]]; then
            echo -e "  ${GREEN}OK${NC}  $name is reachable"
            return 0
        fi
        sleep 2
        attempt=$((attempt + 1))
    done

    echo -e "  ${YELLOW}WARN${NC}  $name is not reachable yet (continuing anyway)"
    return 1
}
