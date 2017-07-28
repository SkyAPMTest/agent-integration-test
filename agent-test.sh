#!/bin/bash
usage(){
	echo "Usage: agent-test.sh [OPTIONS]"
	echo "Options:"
	echo -e "  -r, --repo \t\t\t skywalking repository url"
	echo -e "  -b, --branch, -t, --tag \t skywalking repository branch or tag"
	echo -e "  -p, --only-pull-code \t\t only pull source code, not clone source code"
	echo -e "      --skipReport \t\t skip report "
	echo -e "			 --skipBuild \t\t skip build"
}

# environment check
environmentCheck(){
	echo "Environment List: "
	# check git
	GIT_VERSION=$(git --version)
	if [ $? -ne 0 ];then
		echo " Failed to found git."
		exit 1
	else
		echo " git version: ${GIT_VERSION}"
	fi

	# check maven
	MAVE_VERSION=$(mvn -v | head -n 1)
	if [ $? -ne 0 ];then
		echo " Failed to found maven."
		exit 1
	else
		echo " maven version: $MAVE_VERSION"
	fi

	# check java
	[ -z "$JAVA_HOME" ] && EXECUTE_JAVA=${JAVA_HOME}/bin/java
	if [ "$EXECUTE_JAVA" = "" ]; then
		EXECUTE_JAVA=java
	fi
	JAVA_VERSION=$($EXECUTE_JAVA -version 2>&1 | head -n 1)
	if [ $? -ne 0 ];then
		echo " Failed to found java."
		exit 1
	else
		echo " java version: $JAVA_VERSION"
	fi
}

# clear workspace
clearWorkspace(){
	if [ "$PULL_CODE" = "false" ]; then
		rm -rf $WORKSPACE_DIR/*
	fi
}

# checkout source code
checkoutSourceCode(){
	REPO_URL=$1
	REPO_BRANCH=$2
	SOURCE_CODE_DIR=$3
	if [ "$PULL_CODE" = "false" ]; then
		git clone $REPO_URL "$SOURCE_CODE_DIR"
	fi

	eval "cd $SOURCE_CODE_DIR && git reset --hard && git checkout $REPO_BRANCH && git fetch origin && git pull origin $REPO_BRANCH" 1>&2 > /dev/null
	cd $SOURCE_CODE_DIR && LAST_COMMIT=$(git rev-parse HEAD)
	echo $LAST_COMMIT
}

buildProject(){
	PROJECT_DIR=$1;
	if [ "$SKIP_BUILD" = "false" ]; then
		cd $PROJECT_DIR && mvn clean package
	fi
}

TEST_TOOL_GIT_URL=https://github.com/sky-walking/agent-integration-testtool.git
TEST_TOOL_GIT_BRANCH=master
TEST_CASES_GIT_URL=https://github.com/sky-walking/agent-integration-testcases.git
TEST_CASES_GIT_BRANCH=master
AGENT_GIT_URL=https://github.com/wu-sheng/sky-walking.git
AGENT_GIT_BRANCH=master
REPORT_GIT_URL=https://github.com/sky-walking/agent-integration-test-report.git
REPORT_GIT_BRANCH=master
TEST_TIME=`date "+%Y-%m-%d-%H-%M"`
RECIEVE_DATA_URL=http://127.0.0.1:12800/receiveData
PULL_CODE=false
SKIP_REPORT=false
SKIP_BUILD=false

until [ $# -eq 0 ]
do
	case "$1" in
		-r | --repo )
			AGENT_GIT_URL=$2;
			shift 2;
			;;
		-b | --branch | -t | --tag )
			AGENT_GIT_BRANCH=$2;
			shift 2;
			;;
		-p | --only-pull-code )
			PULL_CODE=true;
			shift;
			;;
		--skipReport )
			SKIP_REPORT=true;
			shift;
			;;
		--skipBuild )
			SKIP_BUILD=true;
			shift;
			;;
		* )
			usage;
			exit 1;
			;;
	esac
done

environmentCheck

PRG="$0"
PRGDIR=`dirname "$PRG"`
[ -z "$AGENT_TEST_HOME" ] && AGENT_TEST_HOME=`cd "$PRGDIR" >/dev/null; pwd`

WORKSPACE_DIR="$AGENT_TEST_HOME/workspace"
echo "clear Workspace"
clearWorkspace

SOURCE_DIR="$WORKSPACE_DIR/sources"

############## build agent ##############
#	1. checkout agent source code
#	2. switch branch
#	3. mvn build
#	4. copy agent to $AGENT_DIR
########################################
echo "clone agent source code"
AGENT_COMMIT=`checkoutSourceCode ${AGENT_GIT_URL} $AGENT_GIT_BRANCH $SOURCE_DIR/skywalking`
#echo "clone agent"
buildProject $SOURCE_DIR/skywalking
echo "agent branch: ${AGENT_GIT_BRANCH}, agent commit: ${AGENT_COMMIT}"
#echo "checkout agent and mvn build"

AGENT_DIR="$WORKSPACE_DIR/agent"
if [ ! -f "${AGENT_DIR}" ]; then
	mkdir -p ${AGENT_DIR}
fi
echo "copy agent jar to $AGENT_DIR"
#echo "copy agent"
cp  $SOURCE_DIR/skywalking/apm-sniffer/apm-agent/target/skywalking-agent.jar $AGENT_DIR

############ build test tool ###########
#	1. checkout test tool code
#	2. switch branch
#	3. mvn build
#	4. copy agent to $WORKSPACE_DIR
########################################
echo "clone test tool source code"
#echo "clone test tool and build"
checkoutSourceCode $TEST_TOOL_GIT_URL $TEST_TOOL_GIT_BRANCH $SOURCE_DIR/test-tools
buildProject $SOURCE_DIR/test-tools
echo "copy test tools to ${WORKSPACE_DIR}"
#echo "copy auto-test.jar"
cp ${SOURCE_DIR}/test-tools/target/skywalking-autotest.jar ${WORKSPACE_DIR}

######### downlod test cases ###########
#	1. checkout test tool code
#	2. switch branch
########################################
echo "clone test cases"
TEST_CASES_DIR="$WORKSPACE_DIR/testcases"
#echo "clone test cases git url"
checkoutSourceCode $TEST_CASES_GIT_URL $TEST_CASES_GIT_BRANCH ${TEST_CASES_DIR}

##### downlod report repository ########
#	1. checkout report repository
#	2. switch branch
########################################
echo "clone report repository"
REPORT_DIR="$WORKSPACE_DIR/report"
#echo "clone report "
checkoutSourceCode ${REPORT_GIT_URL} ${REPORT_GIT_BRANCH} ${REPORT_DIR}

for CASE_DIR in $(ls -d $TEST_CASES_DIR/*/)
do
	ESCAPE_PATH=$(echo "$AGENT_DIR" |sed -e 's/\//\\\//g' )
	eval sed -i -e 's/\{AGENT_FILE_PATH\}/$ESCAPE_PATH/' $CASE_DIR/docker-compose.yml
	echo "start docker container"
	docker-compose -f $CASE_DIR/docker-compose.yml up -d
	sleep 40

	CASE_REQUEST_URL=$(grep "case.request_url" $CASE_DIR/testcase.desc | awk -F '=' '{print $2}')
	echo $CASE_REQUEST_URL
	curl -s $CASE_REQUEST_URL
	sleep 15

	curl -s $RECIEVE_DATA_URL > $CASE_DIR/actualData.yaml

	echo "stop docker container"
	docker-compose -f ${CASE_DIR}/docker-compose.yml stop
done

echo "generate report...."
java -DtestDate="$TEST_TIME" \
	-DagentBranch="$AGENT_GIT_BRANCH" -DagentCommit="$AGENT_COMMIT" \
	-DtestCasePath="$TEST_CASES_DIR" -DreportFilePath="$REPORT_DIR" \
	-jar $WORKSPACE_DIR/skywalking-autotest.jar > $REPORT_DIR/report.log

if [ ! -f "$REPORT_DIR/${AGENT_GIT_BRANCH}" ]; then
	mkdir -p $REPORT_DIR/${AGENT_GIT_BRANCH}
fi
cp -f $REPORT_DIR/report.log $REPORT_DIR/${AGENT_GIT_BRANCH}/report-${TEST_TIME}.log
cp -f $REPORT_DIR/README.md $REPORT_DIR/${AGENT_GIT_BRANCH}/report-${TEST_TIME}.md

if [ "$SKIP_REPORT" = "false" ]; then
	echo "push report...."
	cd $REPORT_DIR
	git add $REPORT_DIR/report.log
	git add $REPORT_DIR/README.md
	git add $REPORT_DIR/${AGENT_GIT_BRANCH}/report-${TEST_TIME}.log
	git add $REPORT_DIR/${AGENT_GIT_BRANCH}/report-${TEST_TIME}.md
	git commit -m "push report report-${TEST_TIME}.md" .
	git push origin master
else
	echo "skipt push report"
fi
