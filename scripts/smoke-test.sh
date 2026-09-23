#!/bin/bash
set -e
export KUBECONFIG=/etc/kubernetes/admin.conf

echo "=== Creating demo namespace and deployment ==="
kubectl create namespace demo
kubectl create deployment hello-web --image=nginx --replicas=3 -n demo
kubectl expose deployment hello-web -n demo --type=NodePort --port=80
NODEPORT=$(kubectl get svc hello-web -n demo -o jsonpath='{.spec.ports[0].nodePort}')
echo "NodePort=$NODEPORT"

echo "=== Wait for pods to be Ready ==="
kubectl wait --for=condition=Ready --timeout=120s pods -l app=hello-web -n demo
kubectl get pods -n demo -o wide

echo
echo "=== Pod-to-pod connectivity (worker-1 -> worker-2) ==="
TARGET=$(kubectl get pod -n demo -l app=hello-web \
  --field-selector=status.phase=Running \
  -o jsonpath='{range .items[?(@.spec.nodeName=="k8s-worker-node-2")]}{.status.podIP}{"\n"}{end}' \
  | head -1)
SOURCE_POD=$(kubectl get pod -n demo -l app=hello-web \
  -o jsonpath='{range .items[?(@.spec.nodeName=="k8s-worker-node-1")]}{.metadata.name}{"\n"}{end}' \
  | head -1)
echo "Source pod: $SOURCE_POD (worker-1) -> target pod IP on worker-2: $TARGET"
kubectl exec -n demo "$SOURCE_POD" -- curl -s -o /dev/null -w "  HTTP %{http_code}\n" "http://$TARGET"

echo
echo "=== DNS resolution ==="
kubectl run -n demo --rm -i --image=busybox --restart=Never nettest -- sh -c 'wget -qO- http://hello-web.demo.svc.cluster.local | head -3; echo "  DNS+svc OK"'

echo
echo "=== Service ClusterIP connectivity ==="
SVCIP=$(kubectl get svc hello-web -n demo -o jsonpath='{.spec.clusterIP}')
echo "ClusterIP: $SVCIP"
kubectl exec -n demo "$SOURCE_POD" -- curl -s -o /dev/null -w "  HTTP %{http_code}\n" "http://$SVCIP"

echo
echo "=== NodePort from worker hosts ==="
curl -s -o /dev/null -w "  10.168.253.29 -> HTTP %{http_code}\n" "http://10.168.253.29:$NODEPORT"
curl -s -o /dev/null -w "  10.168.253.10 -> HTTP %{http_code}\n" "http://10.168.253.10:$NODEPORT"

echo
echo "=== Cleanup ==="
kubectl delete namespace demo --wait=false
echo "OK"