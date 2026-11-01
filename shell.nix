{ pkgs ? import <nixpkgs> {
    config.allowUnfreePredicate = pkg: builtins.elem (builtins.parseDrvName pkg.name).name [ "terraform" ];
  }
}:
pkgs.mkShell {
    packages = with pkgs; [
        talosctl
        terraform
        argocd
        age
        sops
        kubectl
        kubernetes-helm
        talhelper
        k9s
        fluxcd
        prometheus.cli
        apko
        grafana-loki
    ];
}
