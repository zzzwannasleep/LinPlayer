plugins {
    kotlin("jvm") version "1.9.25"
}

repositories { mavenCentral() }

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.3")
}

kotlin {
    sourceSets["main"].kotlin.srcDir(".")
}
