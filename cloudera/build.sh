#!/usr/bin/env bash

# This is the caller script for the build code. build.sh will build for all products.

# If anything fails, then the build should fail.
set -e

#This is needed for cdh_version.properties
BUILD_TIME=$(date +%Y.%m.%d:%H:%M:%S%Z)
GIT_HASH=$(git rev-parse HEAD)

function big_console_header
{
	local text="$*"
	local spacing=$(( (75+${#text}) /2 ))
	printf "\n\n"
	echo "================================================================="
	echo "================================================================="
	printf "%*s\n"  ${spacing} "${text}"
	echo "================================================================="
	echo "================================================================="
	printf "\n\n"
}

#validate jenkins build parameters
if [ ! -z ${RELEASE_CANDIDATE} ]; then
	if [ "${OFFICIAL}" == "false" ]; then
		big_console_header "Build is marked as a Release candidate but it is not official, failing early."
		exit 2
	fi
fi

# if invoked outside of jenkins, setting workspace to parent
if [ -z "$WORKSPACE" ]; then
	WORKSPACE="$(cd .. && pwd)"
fi
# generating a dummy url, if not running from jenkins
if [ -z "$BUILD_URL" ]; then
	BUILD_URL=http://$(hostname)
fi

# removing previous builds
big_console_header "Removing previous artifacts"

rm -rf build-parcel output-repo gbn_build_* cloudera/cdh_version.properties
mvn versions:revert

# Obtain the creds to get s3creds.
wget http://github.mtv.cloudera.com/QE/deploy/raw/master/cdep/data/id_rsa -O /tmp/id_rsa_systest
chmod 600 /tmp/id_rsa_systest

# Retrieve a GBN from the api
export GBN=$(curl http://gbn.infra.cloudera.com/)
if [ -z "$GBN" ]; then
	echo "Could not get GBN for the build"
	exit 1
fi

big_console_header "GBN: $GBN"

export REVNO=${GBN:-0}
export OFFICIAL=${OFFICIAL:false}
export BUILD_TIME=$BUILD_TIME
export GIT_HASH=$GIT_HASH

# getting cdh version from pom.xml
# N.B. this works because we're relying on a released version of CDH
# for the parent (so we can set appropriate versions for CDH components)
# if we switch to developing in concert with a CDH release, we'll
# need to do something like grep the pom to avoid failure when the peer
# cdh directory isn't already on the needed branch.
if CDH_VERSION=$(mvn -q -Dexec.executable='echo' -Dexec.args='${project.parent.version}' \
                     --non-recursive exec:exec) && \
   [ -n "${CDH_VERSION}" ]; then
  big_console_header "Using tooling and component versions from CDH_VERSION: ${CDH_VERSION}"
else
  echo "Couldn't get CDH_VERSION" >&2
  exit 1
fi
export CDH_VERSION

# checking out accumulo in cdh repository
(
	cd ../cdh
	git fetch
        # TODO can we use the "give me the branch name for this version" code from
        # CDH/cdh's HEAD branch?
	git checkout "origin/cdh${CDH_VERSION}"
)

# getting project version from pom.xml (1.9.2-cdh6.0.x-SNAPSHOT -> 1.9.2)
VERSION=$(mvn -q -Dexec.executable='echo' -Dexec.args='${project.version}' --non-recursive exec:exec | sed -e 's/^\([^-]*\)-.*$/\1/')
if [ -z "$VERSION" ]; then
	echo "VERSION is not set correctly"
	exit 1
else
	big_console_header "VERSION: $VERSION"
fi
export VERSION="$VERSION"

# getting current branch from git
BRANCH_NAME=$(git rev-parse --abbrev-ref HEAD)

# generating cdh_version.properties
big_console_header "Generating cdh_version.properties"

cat > cloudera/cdh_version.properties << EOT
# Autogenerated build properties
version=$VERSION
git.hash=$GIT_HASH
cloudera.build-branch=$BRANCH_NAME
cloudera.pkg.version=accumulo${VERSION}-cdh${CDH_VERSION}
cloudera.pkg.release=1.accumulo$VERSION.p0.$REVNO
cloudera.pkg.name=accumulo
cloudera.cdh.release=NA
cloudera.build.time=$BUILD_TIME
EOT

if [ "${OFFICIAL}" == "true" ]; then
	big_console_header "It is an official release, removing -SNAPSHOT"

	mvn versions:set -DremoveSnapshot
fi

# building accumulo
big_console_header "Building accumulo"

mvn clean -DskipTests -Dfindbugs.skip install
mvn -f assemble/pom.xml assembly:single -Ddescriptor=cloudera/maven-repository.xml

build_native() {
	local image="$1"
	local distro="$2"

	local docker_image="docker-registry.infra.cloudera.com/cauldron/$image"

	docker pull "$docker_image"
	if ! docker inspect "$docker_image"; then
        	echo "Docker image not downloaded correctly please check docker image : $docker_image"
        	exit 1
	fi

	docker run \
		-v ${WORKSPACE}/accumulo:/accumulo \
		-v ${WORKSPACE}/cdh:/cdh \
		-e VERSION="${VERSION}" \
		-e GBN="${GBN}" \
		-e DISTRO="$distro" \
		--user=$UID \
		-w /accumulo \
		--entrypoint cloudera/build-parcel.sh \
		"$docker_image"
}

big_console_header "RedHat 6 build"

build_native "redhat6:latest" "el6"

big_console_header "RedHat 7 build"

build_native "redhat7:latest" "el7"

big_console_header "Ubuntu 1604 build"

build_native "ubuntu1604:latest" "xenial"

big_console_header "SLES 12 build"

build_native "sles12:latest" "sles12"

big_console_header "Create Repo, BuildJson and Upload"

# Get the S3 credentials. Needed for pushing final artifacts to the cloud.
ssh -o StrictHostKeyChecking=no -i /tmp/id_rsa_systest s3@cloudcat-s3.infra.cloudera.com build  > ~/.s3-auth-file

# create repos and upload artifacts to s3
DOCKER_IMG="docker-registry.infra.cloudera.com/cauldron/ubuntu1604:latest"
docker pull $DOCKER_IMG
if ! docker inspect $DOCKER_IMG;then
	echo "Docker image not downloaded correctly please check docker image : $DOCKER_IMG"
	exit 1
fi

# This is the post build step. The main idea is to create repos, and upload the artifacts to S3.
# This will need the GBN passed in along with the S3 authorization file.

#	-v $GPG_SIGNING_KEY:$GPG_SIGNING_KEY \
docker run \
	-v ${WORKSPACE}/accumulo:/accumulo \
	-v ${WORKSPACE}/cdh:/cdh \
	-e GBN="${GBN}" \
	-e VERSION="${VERSION}" \
	-e ARTIFACT_VERSION="${ARTIFACT_VERSION}" \
	-e OFFICIAL="${OFFICIAL}" \
	-e RELEASE_CANDIDATE="${RELEASE_CANDIDATE}" \
	-e BUILD_URL=${BUILD_URL} \
	-e GPG_SIGNING_PASSPHRASE=${GPG_SIGNING_PASSPHRASE} \
	-e GPG_SIGNING_KEY=${GPG_SIGNING_KEY} \
	-e USER=$USER \
	--user=$UID \
	-v ~/.s3-auth-file:/tmp/s3-auth-file \
	--entrypoint /accumulo/cloudera/post_build.sh \
	$DOCKER_IMG

# dump s3 output
URL="http://cloudera-build-us-west-1.vpc.cloudera.com/s3/build/$GBN/"

big_console_header "$URL"

# generating html for jenkins
cat > gbn_build_$GBN.html << EOT
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8" />
    <title>$GBN</title>
</head>
<body>
<a href="$URL">$URL</a>
</body>
</html>
EOT
