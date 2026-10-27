#!/usr/bin/env bash
# Removes old Docker Hub banking images from:
#   1. Your local Docker cache (Windows/WSL Docker Desktop)
#   2. minikube's internal containerd cache

DOCKERHUB_USER="jibolaolu"
SERVICES="user-service transaction-service activity-service finance-agent frontend"
CLUSTER="techbleat-bank"

echo "=== Removing Docker Hub images from local Docker cache ==="
for svc in $SERVICES; do
  # Remove all tags for this image (jibolaolu/<service>:*)
  docker images --format "{{.Repository}}:{{.Tag}}" \
    | grep "^${DOCKERHUB_USER}/${svc}:" \
    | xargs -r docker rmi -f 2>/dev/null && \
    echo "  Removed ${DOCKERHUB_USER}/${svc}" || \
    echo "  Nothing to remove for ${DOCKERHUB_USER}/${svc}"
done

echo ""
echo "=== Removing Docker Hub images from minikube containerd ==="
for svc in $SERVICES; do
  # List all tags in minikube's containerd and delete matching ones
  docker exec -i "${CLUSTER}" ctr --namespace k8s.io images list \
    | awk '{print $1}' \
    | grep "docker.io/${DOCKERHUB_USER}/${svc}\|^${DOCKERHUB_USER}/${svc}" \
    | while read -r img; do
        docker exec -i "${CLUSTER}" ctr --namespace k8s.io images rm "${img}" 2>/dev/null && \
          echo "  Removed from minikube: ${img}" || true
      done
done

echo ""
echo "=== Remaining banking images in local Docker cache ==="
docker images | grep -E "user-service|transaction-service|activity-service|finance-agent|frontend" || echo "  None"

echo ""
echo "=== Done. GHCR images (ghcr.io/jibolaolu/*) are untouched. ==="