package dev.lekis.music

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import dagger.hilt.android.AndroidEntryPoint
import dev.lekis.designsystem.LekisTheme
import dev.lekis.music.navigation.LekisApp

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            // TODO：主题模式从设置读取（ThemeMode.System / Light / Dark / OledBlack）
            LekisTheme {
                LekisApp()
            }
        }
    }
}
