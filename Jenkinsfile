#!/usr/bin/env groovy
library 'status-jenkins-lib@v1.9.13'

pipeline {
  agent { label 'linux' }

  options {
    disableConcurrentBuilds()
    /* manage how many builds we keep */
    buildDiscarder(logRotator(
      numToKeepStr: '20',
      daysToKeepStr: '30',
    ))
  }

  stages {
    stage('Build') {
      steps {
        script {
          nix.flake("default")
        }
      }
    }
  }

  post {
    cleanup { cleanWs() }
  }
}
