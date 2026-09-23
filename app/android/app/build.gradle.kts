plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.belgelik.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Varsayilan paket adi com.belgelik.app. Cihazda farkli paket adiyla
        // kurulmus eski bir surum varsa, ikinci bir uygulama yerine onun
        // uzerine yazmak icin appIdOverride tanimlanir. Makineye ozel oldugu
        // icin repo icindeki gradle.properties'e DEGIL, makine genelindeki
        // dosyaya yazilir:
        //   ~/.gradle/gradle.properties -> appIdOverride=<eski.paket.adi>
        // (ORG_GRADLE_PROJECT_ ortam degiskeni "flutter build" uzerinden
        // gradle'a gecmiyor, o yolu kullanma.)
        applicationId = (project.findProperty("appIdOverride") as String?)
            ?: "com.belgelik.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
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

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
