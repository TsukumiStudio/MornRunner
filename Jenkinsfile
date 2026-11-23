// ビルドとテストだけ。リリース・署名・tap 更新は .github/workflows/release.yml のまま
@Library('MornJenkins') _
pipeline {
  agent { label 'built-in' }
  options {
    timestamps()
    timeout(time: 30, unit: 'MINUTES')
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '3'))
  }
  stages {
    stage('Tools') {
      steps { mornToolVersions() }
    }
    stage('Lint') {
      steps {
        sh 'zsh -n build.sh'
        sh 'ruby -c Support/mornrunner.rb.in'
      }
    }
    stage('Test') {
      steps { sh 'swift test' }
    }
    stage('Build') {
      steps { sh 'UNIVERSAL=1 zsh build.sh' }
    }
    stage('Verify') {
      steps {
        sh '''
          app=dist/MornRunner.app
          test "$(lipo -archs "$app/Contents/MacOS/MornRunner" | tr ' ' '\\n' | sort | xargs)" = "arm64 x86_64"
          codesign --verify --strict -vv "$app"
          test -s "$app/Contents/Resources/AppIcon.icns"
          test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" = studio.tsukumi.MornRunner
        '''
        archiveArtifacts artifacts: 'dist/MornRunner.app.zip', fingerprint: true
      }
    }
  }
}
