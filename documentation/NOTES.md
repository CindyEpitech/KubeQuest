## KUBE

To start using your cluster, you need to run the following as a regular user:

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

Alternatively, if you are the root user, you can run:

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
```

You should now deploy a pod network to the cluster.
Run `kubectl apply -f [podnetwork].yaml` with one of the options listed at:
  https://kubernetes.io/docs/concepts/cluster-administration/addons/


Then you can join any number of worker nodes by running the following on each as root:

```bash
sudo kubeadm join 10.0.9.227:6443 --token cvfpkp.sfzmbefcgmby9o82 \
        --discovery-token-ca-cert-hash sha256:428e9f191813e4a93b7b356be99de4bd7b3e010aeacdfe51b78882e5b558f6ed
```



## PROMETHEUS

kube-prometheus-stack has been installed. Check its status by running:

```bash
kubectl --namespace monitoring get pods -l "release=kube-prometheus"
```

Get Grafana 'admin' user password by running:

```bash
kubectl --namespace monitoring get secrets kube-prometheus-grafana -o jsonpath="{.data.admin-password}" | base64 -d ; echo
```

Access Grafana local instance:

```bash
export POD_NAME=$(kubectl --namespace monitoring get pod -l "app.kubernetes.io/name=grafana,app.kubernetes.io/instance=kube-prometheus" -oname)
kubectl --namespace monitoring port-forward $POD_NAME 3000
```

Get your grafana admin user password by running:

```bash
kubectl get secret --namespace monitoring -l app.kubernetes.io/component=admin-secret -o jsonpath="{.items[0].data.admin-password}" | base64 --decode ; echo
```

Visit https://github.com/prometheus-operator/kube-prometheus for instructions on how to create & configure Alertmanager and Prometheus instances using the Operator.


## 