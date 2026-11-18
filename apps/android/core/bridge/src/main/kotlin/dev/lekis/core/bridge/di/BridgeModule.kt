package dev.lekis.core.bridge.di

import android.content.Context
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import dev.lekis.core.bridge.CoreBridge
import dev.lekis.core.bridge.RustCoreBridge
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object BridgeModule {
    @Provides
    @Singleton
    fun provideCoreBridge(@ApplicationContext context: Context): CoreBridge = RustCoreBridge(context)
}
