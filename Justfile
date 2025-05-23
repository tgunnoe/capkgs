# List available just tasks
list:
    just -l

secret_key := env_var_or_default('NIX_SIGNING_KEY_FILE', "hydra_key")

# Based on projects.json, upload the CA contents and update packages.json
packages *ARGS:
    ./packages.cr \
        --to "s3://cache.sc.iog.io?secret-key={{secret_key}}&region=${AWS_REGION}&compression=zstd" \
        --from-store https://cache.iog.io \
        --systems x86_64-linux,aarch64-darwin

# Based on projects.json, upload the CA contents and update packages.json
ci:
    @just -v cache-download
    @just -v packages
    @just -v cache-upload

# download and uncompress the cache folder
cache-download:
    @just -v rclone copyto s3://cache.sc.iog.io/capkgs/cache.tar.zst cache.tar.zst
    tar xf cache.tar.zst

# compress and upload the cache folder
cache-upload:
    tar cfa cache.tar.zst cache
    @just -v rclone copyto cache.tar.zst s3://cache.sc.iog.io/capkgs/cache.tar.zst

rclone *ARGS:
    #!/usr/bin/env nu
    if $env.CI? == "true" { $env.HOME = $env.PWD }

    if $env.AWS_PROFILE? == null {
        if $env.AWS_ACCESS_KEY_ID? == null and $env.AWS_SECRET_ACCESS_KEY? == null {
            print "Both AWS_PROFILE and AWS keypair (AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY) environment variables are not set."
            print "Set appropriate AWS env vars and try again."
            exit 1
        }
    }

    if $env.S3_ENDPOINT? == null {
        print "The S3_ENDPOINT environment variable is unset.  Please set and try again."
        exit 1
    }

    mkdir .config/rclone
    rclone config create s3 s3 env_auth=true | save -f .config/rclone/rclone.conf
    rclone --s3-provider Cloudflare --s3-region auto --s3-endpoint $env.S3_ENDPOINT --verbose {{ARGS}}

push:
    git add packages.json
    git commit -m 'Update packages.json'

# Attempt to build all packages from this flake
check:
    #!/usr/bin/env nu

    # Systems to check
    let systems = ["x86_64-linux", "aarch64-darwin"]

    # Check each system
    for system in $systems {
        echo $"\nChecking packages for ($system)..."

        # Obtain the package set
        let pkgs = (do { nix eval ".#packages.$system" --apply builtins.attrNames --json } | complete)
        
        if $pkgs.exit_code != 0 {
            echo $"Error getting packages for ($system): ($pkgs.stderr)"
            continue
        }
        
        let pkgs_list = ($pkgs.stdout | from json)
        
        # Display packages
        echo $"Packages for ($system):"
        echo $pkgs_list
        echo ""

        # Obtain a drv for each package since building direct attrs with embedded '"' doesn't work
        if $system == (uname -m) + "-" + (uname -s | str downcase) {
            echo $"Evaluating derivations for ($system)..."
            let drvs = ($pkgs_list | par-each {|pkg|
                print $"Eval drv for package ($pkg)..."
                do { nix eval ".#packages.$system" --raw --apply $"'pkgs: pkgs."($pkg | str replace '"' '\"' --all)".drvPath'" }
                    | complete
            })

            # Obtain package builds from the drvs
            echo $"Building packages for ($system)..."
            let $builds = ($drvs | par-each {|drv|
                print $"Building ($drv.stdout)..."
                do { nix build --no-link --print-out-paths $"($drv.stdout)^*" }
                    | complete
            })

            echo "Derivations results:"
            echo $drvs | table -e
            echo ""

            echo "Build results:"
            echo $builds | table -e
            echo ""
        } else {
            echo $"Skipping building for non-native ($system)"
        }
    }

