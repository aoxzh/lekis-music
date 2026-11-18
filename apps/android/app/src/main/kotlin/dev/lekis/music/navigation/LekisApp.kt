package dev.lekis.music.navigation

import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.LibraryMusic
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import dev.lekis.music.R
import dev.lekis.music.feature.home.HomeScreen
import dev.lekis.music.feature.library.LibraryScreen
import dev.lekis.music.feature.nowplaying.MiniPlayer
import dev.lekis.music.feature.nowplaying.NowPlayingScreen
import dev.lekis.music.feature.search.SearchScreen
import dev.lekis.music.feature.settings.SettingsScreen
import dev.lekis.music.feature.sources.SourcesScreen

/** 路由。页面划分和 Windows 端保持一致（docs/ARCHITECTURE.md 第 7 节）。 */
object Routes {
    const val HOME = "home"
    const val LIBRARY = "library"
    const val SEARCH = "search"
    const val SETTINGS = "settings"
    const val NOW_PLAYING = "now_playing"
    const val SOURCES = "sources"
    // TODO：album/{id}、artist/{id}、playlist/{id}、enrich_review
}

private enum class Tab(val route: String, @StringRes val label: Int, val icon: ImageVector) {
    Home(Routes.HOME, R.string.tab_home, Icons.Filled.Home),
    Library(Routes.LIBRARY, R.string.tab_library, Icons.Filled.LibraryMusic),
    Search(Routes.SEARCH, R.string.tab_search, Icons.Filled.Search),
    Settings(Routes.SETTINGS, R.string.tab_settings, Icons.Filled.Settings),
}

@Composable
fun LekisApp() {
    val nav = rememberNavController()
    val backStack by nav.currentBackStackEntryAsState()
    val destination = backStack?.destination
    val showChrome = destination?.route != Routes.NOW_PLAYING

    Scaffold(
        bottomBar = {
            if (showChrome) {
                Column {
                    MiniPlayer(onExpand = { nav.navigate(Routes.NOW_PLAYING) })
                    NavigationBar {
                        Tab.entries.forEach { tab ->
                            val selected = destination?.hierarchy?.any { it.route == tab.route } == true
                            NavigationBarItem(
                                selected = selected,
                                onClick = {
                                    nav.navigate(tab.route) {
                                        popUpTo(nav.graph.findStartDestination().id) { saveState = true }
                                        launchSingleTop = true
                                        restoreState = true
                                    }
                                },
                                icon = { Icon(tab.icon, contentDescription = null) },
                                label = { Text(stringResource(tab.label)) },
                            )
                        }
                    }
                }
            }
        },
    ) { padding ->
        NavHost(nav, startDestination = Routes.HOME, modifier = Modifier.padding(padding)) {
            composable(Routes.HOME) { HomeScreen(onAddSource = { nav.navigate(Routes.SOURCES) }) }
            composable(Routes.LIBRARY) { LibraryScreen() }
            composable(Routes.SEARCH) { SearchScreen() }
            composable(Routes.SETTINGS) { SettingsScreen(onOpenSources = { nav.navigate(Routes.SOURCES) }) }
            composable(Routes.SOURCES) { SourcesScreen() }
            composable(Routes.NOW_PLAYING) { NowPlayingScreen(onCollapse = { nav.popBackStack() }) }
        }
    }
}
