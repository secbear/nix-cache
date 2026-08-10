{ inputs, ... }:
{
  perSystem =
    {
      config,
      pkgs,
      system,
      ...
    }:
    let
      mkProjectScript = import ../lib/mk-project-script.nix { inherit pkgs; };

      niks3Image = "ghcr.io/mic92/niks3:v1.4.0@sha256:fcbeef12785af2048250022a02e6830efe67dcc26eeb765ce87a0a93a7a28449";
      niks3Cli = inputs.niks3.packages.${system}.niks3;
      tfDir = "infra/opentofu";
      tfVarsFile = "infra/opentofu/stack.auto.tfvars.json";
      tfVarsExampleFile = "infra/opentofu/stack.auto.tfvars.example.json";
      flyTemplate = "fly/fly.toml.tmpl";
      flyConfig = "fly/fly.toml";

      rootPrelude = ''
        PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
        cd "$PROJECT_ROOT"
      '';

      shellHelpers = ''
        SCRIPT_SELF="$0"
        SCRIPT_ARGS=("$@")

        ensure_env() {
          local key=""
          local missing=()

          for key in "$@"; do
            if [ -z "''${!key:-}" ]; then
              missing+=("$key")
            fi
          done

          if [ "''${#missing[@]}" -eq 0 ]; then
            return 0
          fi

          if [ -z "''${BWS_REEXEC:-}" ] \
            && [ -n "''${BWS_ACCESS_TOKEN:-}" ] \
            && [ -n "''${BWS_PROJECT_ID:-}" ] \
            && command -v bws >/dev/null 2>&1; then
            export BWS_REEXEC=1
            exec bws run --project-id "$BWS_PROJECT_ID" -- "$SCRIPT_SELF" "''${SCRIPT_ARGS[@]}"
          fi

          printf 'missing env %s\n' "''${missing[@]}" >&2
          echo "export the required env vars directly, or set BWS_ACCESS_TOKEN and BWS_PROJECT_ID" >&2
          exit 1
        }
      '';
    in
    {
      packages = {
        fmt = mkProjectScript {
          name = "fmt";
          runtimeInputs = [
            config.treefmt.build.wrapper
            pkgs.opentofu
          ];
          text = ''
            ${rootPrelude}
            ${shellHelpers}

            treefmt
            tofu -chdir=${tfDir} fmt -recursive
          '';
        };

        lint = mkProjectScript {
          name = "lint";
          runtimeInputs = [
            config.treefmt.build.wrapper
            pkgs.opentofu
          ];
          text = ''
            ${rootPrelude}
            ${shellHelpers}

            treefmt --fail-on-change
            tofu -chdir=${tfDir} fmt -check -recursive
            tofu -chdir=${tfDir} init -backend=false -input=false >/dev/null
            tofu -chdir=${tfDir} validate
          '';
        };

        init-config = mkProjectScript {
          name = "init-config";
          runtimeInputs = [ pkgs.coreutils ];
          text = ''
            ${rootPrelude}
            ${shellHelpers}

            if [ -f "${tfVarsFile}" ]; then
              echo "${tfVarsFile} already exists"
              exit 0
            fi

            cp "${tfVarsExampleFile}" "${tfVarsFile}"
            echo "created ${tfVarsFile} from ${tfVarsExampleFile}"
            echo "edit ${tfVarsFile} with your local values before running plan/up"
          '';
        };

        render-fly-config = mkProjectScript {
          name = "render-fly-config";
          runtimeInputs = [
            pkgs.coreutils
            pkgs.gawk
            pkgs.gnused
            pkgs.jq
            pkgs.opentofu
          ];
          text = ''
            ${rootPrelude}
            ${shellHelpers}

            if [ ! -f "${tfVarsFile}" ]; then
              echo "missing ${tfVarsFile}; run init-config or copy ${tfVarsExampleFile}" >&2
              exit 1
            fi

            if [ ! -f "${flyTemplate}" ]; then
              echo "missing ${flyTemplate}" >&2
              exit 1
            fi

            fly_env_json="$(tofu -chdir=${tfDir} output -json fly_env)"
            app_name="$(jq -r '.fly_app_name' ${tfVarsFile})"
            primary_region="$(jq -r '.fly_primary_region' ${tfVarsFile})"
            vm_cpu_kind="$(jq -r '.fly_vm_cpu_kind' ${tfVarsFile})"
            vm_cpus="$(jq -r '.fly_vm_cpus' ${tfVarsFile})"
            vm_memory="$(jq -r '.fly_vm_memory' ${tfVarsFile})"
            swap_size_mb="$(jq -r '.fly_swap_size_mb' ${tfVarsFile})"

            env_block="$(
              jq -r '
                to_entries
                | sort_by(.key)
                | map("  \(.key) = \"\(.value)\"")
                | join("\n")
              ' <<<"$fly_env_json"
            )"

            mkdir -p "$(dirname ${flyConfig})"

            awk \
              -v app_name="$app_name" \
              -v primary_region="$primary_region" \
              -v image="${niks3Image}" \
              -v env_block="$env_block" \
              -v vm_cpu_kind="$vm_cpu_kind" \
              -v vm_cpus="$vm_cpus" \
              -v vm_memory="$vm_memory" \
              -v swap_size_mb="$swap_size_mb" '
                {
                  gsub("__APP_NAME__", app_name)
                  gsub("__PRIMARY_REGION__", primary_region)
                  gsub("__IMAGE__", image)
                  gsub("__VM_CPU_KIND__", vm_cpu_kind)
                  gsub("__VM_CPUS__", vm_cpus)
                  gsub("__VM_MEMORY__", vm_memory)
                  gsub("__SWAP_SIZE_MB__", swap_size_mb)
                }
                $0 == "__ENV_BLOCK__" {
                  print env_block
                  next
                }
                { print }
              ' "${flyTemplate}" > "${flyConfig}"

            echo "rendered ${flyConfig}"
          '';
        };

        deploy = mkProjectScript {
          name = "deploy";
          runtimeInputs = [
            pkgs.coreutils
            pkgs.flyctl
            pkgs.jq
            pkgs.opentofu
          ];
          text = ''
            ${rootPrelude}
            ${shellHelpers}

            if [ ! -f "${tfVarsFile}" ]; then
              echo "missing ${tfVarsFile}; run init-config or copy ${tfVarsExampleFile}" >&2
              exit 1
            fi

            ensure_env \
              FLY_API_TOKEN \
              NIKS3_API_TOKEN \
              NIKS3_DB \
              NIKS3_S3_ACCESS_KEY \
              NIKS3_S3_SECRET_KEY \
              NIKS3_SIGNING_KEY

            ${config.packages.render-fly-config}/bin/render-fly-config

            app_name="$(jq -r '.fly_app_name' ${tfVarsFile})"
            fly_org_slug="$(jq -r '.fly_org_slug // empty' ${tfVarsFile})"

            if ! flyctl apps show "$app_name" >/dev/null 2>&1; then
              if [ -z "$fly_org_slug" ]; then
                orgs_json="$(flyctl orgs list --json)"
                org_count="$(jq 'length' <<<"$orgs_json")"
                if [ "$org_count" -eq 1 ]; then
                  fly_org_slug="$(jq -r '.[0].slug' <<<"$orgs_json")"
                else
                  echo "fly app $app_name does not exist and fly_org_slug is unset" >&2
                  echo "set fly_org_slug in ${tfVarsFile}, or make sure exactly one Fly org is accessible" >&2
                  exit 1
                fi
              fi

              flyctl apps create --name "$app_name" --org "$fly_org_slug" --yes

              if ! flyctl apps show "$app_name" >/dev/null 2>&1; then
                echo "fly app creation did not produce an accessible app: $app_name" >&2
                echo "verify Fly billing is enabled and the target org is correct" >&2
                exit 1
              fi
            fi

            signing_key_b64="$(printf '%s' "$NIKS3_SIGNING_KEY" | base64 | tr -d '\n')"
            oidc_config_json="$(tofu -chdir=${tfDir} output -raw oidc_config_json)"
            oidc_config_b64="$(printf '%s' "$oidc_config_json" | base64 | tr -d '\n')"

            merged_json="$(
              jq -n \
                --arg NIKS3_API_TOKEN "$NIKS3_API_TOKEN" \
                --arg NIKS3_DB "$NIKS3_DB" \
                --arg NIKS3_S3_ACCESS_KEY "$NIKS3_S3_ACCESS_KEY" \
                --arg NIKS3_S3_SECRET_KEY "$NIKS3_S3_SECRET_KEY" \
                --arg NIKS3_SIGNING_KEY_FILE_B64 "$signing_key_b64" \
                --arg NIKS3_OIDC_CONFIG_B64 "$oidc_config_b64" '
                  {
                    NIKS3_API_TOKEN: $NIKS3_API_TOKEN,
                    NIKS3_DB: $NIKS3_DB,
                    NIKS3_S3_ACCESS_KEY: $NIKS3_S3_ACCESS_KEY,
                    NIKS3_S3_SECRET_KEY: $NIKS3_S3_SECRET_KEY,
                    NIKS3_SIGNING_KEY_FILE_B64: $NIKS3_SIGNING_KEY_FILE_B64,
                    NIKS3_OIDC_CONFIG_B64: $NIKS3_OIDC_CONFIG_B64
                  }
                '
            )"

            tmpfile="$(mktemp)"
            trap 'rm -f "$tmpfile"' EXIT

            jq -r 'to_entries[] | "\(.key)=\(.value)"' <<<"$merged_json" > "$tmpfile"

            flyctl secrets import --app "$app_name" < "$tmpfile"
            flyctl deploy --app "$app_name" --config ${flyConfig} --ha=false
          '';
        };

        plan = mkProjectScript {
          name = "plan";
          runtimeInputs = [
            pkgs.opentofu
          ];
          text = ''
            ${rootPrelude}
            ${shellHelpers}

            ensure_env CLOUDFLARE_API_TOKEN
            tofu -chdir=${tfDir} init -input=false
            tofu -chdir=${tfDir} plan
          '';
        };

        gc = mkProjectScript {
          name = "gc";
          runtimeInputs = [
            pkgs.coreutils
            pkgs.jq
            niks3Cli
          ];
          text = ''
            ${rootPrelude}
            ${shellHelpers}

            if [ "''${1:-}" = "--help" ] || [ "''${1:-}" = "-h" ]; then
              exec ${niks3Cli}/bin/niks3 gc --help
            fi

            if [ ! -f "${tfVarsFile}" ]; then
              echo "missing ${tfVarsFile}; run init-config or copy ${tfVarsExampleFile}" >&2
              exit 1
            fi

            ensure_env NIKS3_API_TOKEN

            app_name="$(jq -r '.fly_app_name' ${tfVarsFile})"
            server_url="''${NIKS3_SERVER_URL:-https://$app_name.fly.dev}"

            umask 077
            token_file="$(mktemp "''${TMPDIR:-/tmp}/niks3-auth-token.XXXXXX")"
            trap 'rm -f -- "$token_file"' EXIT
            printf '%s' "$NIKS3_API_TOKEN" >"$token_file"
            unset NIKS3_API_TOKEN

            NIKS3_AUTH_TOKEN_FILE="$token_file" ${niks3Cli}/bin/niks3 gc \
              --server-url "$server_url" \
              --older-than 876000h \
              --failed-uploads-older-than 6h \
              "$@"
          '';
        };

        status = mkProjectScript {
          name = "status";
          runtimeInputs = [
            pkgs.flyctl
            pkgs.jq
            pkgs.opentofu
          ];
          text = ''
            ${rootPrelude}
            ${shellHelpers}

            if [ -f "${tfVarsFile}" ]; then
              app_name="$(jq -r '.fly_app_name' ${tfVarsFile})"
            else
              app_name=""
            fi

            if [ -d "${tfDir}" ]; then
              tofu -chdir=${tfDir} output public_endpoints 2>/dev/null || true
            fi

            if [ -n "$app_name" ]; then
              flyctl status --app "$app_name" || true
            fi
          '';
        };

        up = mkProjectScript {
          name = "up";
          runtimeInputs = [
            pkgs.opentofu
            config.packages.deploy
          ];
          text = ''
            ${rootPrelude}
            ${shellHelpers}

            ensure_env CLOUDFLARE_API_TOKEN
            tofu -chdir=${tfDir} init -input=false
            tofu -chdir=${tfDir} apply -auto-approve
            ${config.packages.deploy}/bin/deploy
          '';
        };

        down = mkProjectScript {
          name = "down";
          runtimeInputs = [
            pkgs.flyctl
            pkgs.jq
            pkgs.opentofu
          ];
          text = ''
            ${rootPrelude}
            ${shellHelpers}

            ensure_env CLOUDFLARE_API_TOKEN FLY_API_TOKEN

            if [ -f "${tfVarsFile}" ]; then
              app_name="$(jq -r '.fly_app_name' ${tfVarsFile})"
              if flyctl apps show "$app_name" >/dev/null 2>&1; then
                flyctl apps destroy "$app_name" --yes
              fi
            fi

            tofu -chdir=${tfDir} init -input=false
            tofu -chdir=${tfDir} destroy -auto-approve
          '';
        };

        default = config.packages.status;
      };
    };
}
