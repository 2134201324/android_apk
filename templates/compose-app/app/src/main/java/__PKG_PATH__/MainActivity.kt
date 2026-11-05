package __PKG__

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp

/**
 * 应用入口。整个 App 的面板从 [App] 往下长，MainActivity 只负责挂载。
 *
 * 三个容易踩的点：
 * 1. 不要在这里做耗时初始化（读数据库、请求网络）。它跑在主线程，
 *    超过 5 秒就是 ANR；用 LaunchedEffect 或 Application.onCreate 的后台协程。
 * 2. setContent 里读到的状态必须是 Compose State（mutableStateOf），
 *    普通 var 改了不会触发重组，表现为「点了没反应」。
 * 3. 主题只在一处套（这里），页面内部不要再包 MaterialTheme，否则深色模式会花。
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            MaterialTheme {
                App()
            }
        }
    }
}

@Composable
private fun App() {
    // 这是模板自带的「能跑起来」的最小交互，用来验证构建链路。
    // 写业务时整块替换掉。
    var count by remember { mutableIntStateOf(0) }

    Scaffold(modifier = Modifier.fillMaxSize()) { inner ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(inner)
                .padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text(
                text = stringResource(R.string.app_name),
                style = MaterialTheme.typography.headlineMedium
            )
            Text(text = "点击次数：$count", style = MaterialTheme.typography.bodyLarge)
            Button(onClick = { count++ }) {
                Text("点我")
            }
        }
    }
}
