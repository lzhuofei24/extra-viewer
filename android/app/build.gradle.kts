import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseSigningFile = file(
    System.getenv("EXTRA_VIEWER_SIGNING_PROPERTIES")
        ?: "${System.getProperty("user.home")}/.extra-viewer/signing/key.properties"
)
val releaseSigning = Properties()
val hasReleaseSigning = releaseSigningFile.isFile
if (hasReleaseSigning) {
    FileInputStream(releaseSigningFile).use(releaseSigning::load)
}

dependencies {
    implementation("androidx.documentfile:documentfile:1.0.1")
}

android {
    namespace = "com.lzhuofei.extraviewer"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.lzhuofei.extraviewer"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(releaseSigning.getProperty("storeFile"))
                storePassword = releaseSigning.getProperty("storePassword")
                keyAlias = releaseSigning.getProperty("keyAlias")
                keyPassword = releaseSigning.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                null
            }
        }
    }
}

gradle.taskGraph.whenReady {
    val requestsRelease = allTasks.any {
        it.name.contains("release", ignoreCase = true)
    }
    if (requestsRelease && !hasReleaseSigning) {
        throw GradleException(
            "Extra Viewer release signing is missing: ${releaseSigningFile.absolutePath}"
        )
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
