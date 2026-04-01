#!/usr/bin/env bash
# Determine nn6000v2 path
if [ -d "nn6000v2" ]; then
    NN6000V2_PATH="nn6000v2"
elif [ -d "../nn6000v2" ]; then
    NN6000V2_PATH="../nn6000v2"
else
    # Fallback to parent directory of script directory
    NN6000V2_PATH=$(dirname "$(dirname "$0")")
fi

BASE_PATH=$(cd "$NN6000V2_PATH" && pwd)

Dev=$1

INI_FILE="$BASE_PATH/configs/$Dev.ini"

if [[ ! -f $INI_FILE ]]; then
    echo "INI file not found: $INI_FILE"
    exit 1
fi

read_ini_by_key() {
    local key=$1
    awk -F"=" -v key="$key" '$1 == key {print $2}' "$INI_FILE"
}

REPO_URL=$(read_ini_by_key "REPO_URL")
REPO_BRANCH=$(read_ini_by_key "REPO_BRANCH")
REPO_BRANCH=${REPO_BRANCH:-main}
# GitHub Actions usually runs in root of repo, so build dir should be relative to repo root
# We need to construct absolute path or ensure context is correct.
# Assuming this script is run from repo root or nn6000v2.
# Let's use relative path "action_build" next to nn6000v2 if possible or just use what works.
# Original script used BASE_PATH/action_build.
BUILD_DIR="$BASE_PATH/../action_build"

echo $REPO_URL $REPO_BRANCH
# Write flag one level up from nn6000v2 (repo root usually)
echo "$REPO_URL/$REPO_BRANCH" >"$BASE_PATH/../repo_flag"
git clone --depth 1 -b $REPO_BRANCH $REPO_URL $BUILD_DIR

# GitHub Action 移除国内下载源
PROJECT_MIRRORS_FILE="$BUILD_DIR/scripts/projectsmirrors.json"

if [ -f "$PROJECT_MIRRORS_FILE" ]; then
    sed -i '/.cn\//d; /tencent/d; /aliyun/d' "$PROJECT_MIRRORS_FILE"
fi
