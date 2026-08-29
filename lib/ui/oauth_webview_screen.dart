import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// In-app OAuth consent: loads [authorizeUrl] and intercepts the
/// first navigation to [callbackScheme]://, popping with the full
/// callback URL. Exists because Chrome Custom Tabs silently block
/// the post-consent redirect to a custom scheme on some providers
/// (Withings included) — inside our own WebView the navigation is
/// ours to catch before Android routing is involved.
class OAuthWebViewScreen extends StatefulWidget {
  const OAuthWebViewScreen({
    super.key,
    required this.title,
    required this.authorizeUrl,
    required this.callbackScheme,
  });

  final String title;
  final Uri authorizeUrl;
  final String callbackScheme;

  @override
  State<OAuthWebViewScreen> createState() => _OAuthWebViewScreenState();
}

class _OAuthWebViewScreenState extends State<OAuthWebViewScreen> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (request) {
          if (request.url.startsWith('${widget.callbackScheme}://')) {
            Navigator.of(context).pop(request.url);
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ))
      ..loadRequest(widget.authorizeUrl);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: WebViewWidget(controller: _controller),
    );
  }
}
