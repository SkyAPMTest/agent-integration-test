#!/bin/bash
TEST_TOOL_GIT_URL=https://github.com/sky-walking/agent-integration-testtool.git
TEST_TOOL_GIT_BRANCH=master
TEST_CASES_GIT_URL=https://github.com/sky-walking/agent-integration-testcases.git
TEST_CASES_GIT_BRANCH=master
AGENT_GIT_URL=https://github.com/wu-sheng/sky-walking.git
AGENT_GIT_BRANCH=master
REPORT_GIT_URL=https://github.com/sky-walking/agent-integration-test-report.git
TEST_TIME=`date "+%Y-%m-%d-%H-%M"`
RECIEVE_DATA_URL=http://127.0.0.1:12800/receiveData

function environmentCheck(){
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

environmentCheck

PRG="$0"
PRGDIR=`dirname "$PRG"`
[ -z "$AGENT_TEST_HOME" ] && AGENT_TEST_HOME=`cd "$PRGDIR" >/dev/null; pwd`

WORKSPACE_DIR="$AGENT_TEST_HOME/workspace"

function clearWorkspace(){
	rm -rf $WORKSPACE_DIR/*
}
echo "clear Workspace"
clearWorkspace

SOURCE_DIR="$WORKSPACE_DIR/sources"

echo "clone agent source code"
#echo "clone agent"
git clone "${AGENT_GIT_URL}" "$SOURCE_DIR/skywalking"
cd $SOURCE_DIR/skywalking 
AGENT_COMMIT=$(git rev-parse HEAD)
echo "agent branch: ${AGENT_GIT_BRANCH}, agent commit: ${AGENT_COMMIT}"
#echo "checkout agent and mvn build"
git checkout ${AGENT_GIT_BRANCH} && mvn package

AGENT_DIR="$WORKSPACE_DIR/agent"
if [ ! -f "${AGENT_DIR}" ]; then
	mkdir -p ${AGENT_DIR}
fi
echo "copy agent jar to $AGENT_DIR"
#echo "copy agent"
cp  $SOURCE_DIR/skywalking/apm-sniffer/apm-agent/target/skywalking-agent.jar $AGENT_DIR

echo "clone test tool source code"
#echo "clone test tool and build"
git clone $TEST_TOOL_GIT_URL "$SOURCE_DIR/test-tools"
cd $SOURCE_DIR/test-tools && git checkout ${TEST_TOOL_GIT_BRANCH} && mvn package
echo "copy test tools to ${WORKSPACE_DIR}"
#echo "copy auto-test.jar"
cp ${SOURCE_DIR}/test-tools/target/skywalking-autotest.jar ${WORKSPACE_DIR}

echo "clone test cases"
TEST_CASES_DIR="$WORKSPACE_DIR/testcases"
#echo "clone test cases git url"
git clone $TEST_CASES_GIT_URL "${TEST_CASES_DIR}"

echo "clone report repository"
REPORT_DIR="$WORKSPACE_DIR/report"
#echo "clone report "
git clone ${REPORT_GIT_URL} "${REPORT_DIR}"

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
	sleep 10

	curl -s $RECIEVE_DATA_URL > $CASE_DIR/actualData.yaml

	echo "stop docker container"
	docker-compose -f ${CASE_DIR}/docker-compose.yml stop
done

echo "generate report...."
java -DtestDate=$TEST_TIME \
	-DagentBranch=$AGENT_GIT_BRANCH -DagentCommit=$AGENT_COMMIT \
	-DtestCasePath=$TEST_CASES_DIR -DreportFilePath=$REPORT_DIR \
	-jar $WORKSPACE_DIR/skywalking-autotest.jar  > $REPORT_DIR/report.log
if [ ! -f "$REPORT_DIR/${AGENT_GIT_BRANCH}" ]; then
	mkdir -p $REPORT_DIR/${AGENT_GIT_BRANCH}
fi
cp -f $REPORT_DIR/report.log $REPORT_DIR/${AGENT_GIT_BRANCH}/report-${TEST_TIME}.log
cp -f $REPORT_DIR/README.md $REPORT_DIR/${AGENT_GIT_BRANCH}/report-${TEST_TIME}.md

echo "push report...."
cd $REPORT_DIR 
git add $REPORT_DIR/report.log
git add $REPORT_DIR/README.md
git add $REPORT_DIR/${AGENT_GIT_BRANCH}/report-${TEST_TIME}.log
git add $REPORT_DIR/${AGENT_GIT_BRANCH}/report-${TEST_TIME}.md
git commit -m "push report report-${TEST_TIME}.md" .
git push origin master




