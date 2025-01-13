# To use:
# ./run.sh namespace1/pvc_name1 namespace2/pvc_name2 [...]

set -e

for pvc in $@; do
    namespace=$(echo $pvc | cut -d '/' -f 1)
    pvc_name=$(echo $pvc | cut -d '/' -f 2)
    mkdir -p $namespace-$pvc_name/
    sed "s/PVC_NAME/$pvc_name/g" pod.yaml | kubectl apply -n $namespace -f -
    kubectl wait --for=condition=Ready pod/copy-data -n $namespace
    kubectl cp --retries=-1 copy-data:/data/ $PWD/$namespace-$pvc_name/ -n $namespace
    kubectl delete pod copy-data -n $namespace
done
