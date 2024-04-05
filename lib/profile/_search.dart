import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_triple/flutter_triple.dart';
import 'package:infinite_scroll_pagination/infinite_scroll_pagination.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:squawker/client/client.dart';
import 'package:squawker/client/client_account.dart';
import 'package:squawker/constants.dart';
import 'package:squawker/database/entities.dart';
import 'package:squawker/generated/l10n.dart';
import 'package:squawker/profile/profile.dart';
import 'package:squawker/search/search_model.dart';
import 'package:squawker/subscriptions/users_model.dart';
import 'package:squawker/tweet/_video.dart';
import 'package:squawker/tweet/tweet.dart';
import 'package:squawker/ui/errors.dart';
import 'package:squawker/user.dart';
import 'package:squawker/utils/notifiers.dart';
import 'package:pref/pref.dart';
import 'package:provider/provider.dart';

class SearchScreen extends StatelessWidget {
  final String screenName;
  const SearchScreen(this.screenName, {Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return _SearchScreen(screenName: screenName);
  }
}

class _SearchScreen extends StatefulWidget {
  final String screenName;

  const _SearchScreen({Key? key, required this.screenName}) : super(key: key);

  @override
  State<_SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<_SearchScreen> with SingleTickerProviderStateMixin {
  final TextEditingController _queryController = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  final GlobalKey<TweetSearchResultListState> _searchUsersKey = GlobalKey<TweetSearchResultListState>();
  final GlobalKey<TweetSearchResultListState> _searchTweetsKey = GlobalKey<TweetSearchResultListState>();
  final GlobalKey<TweetSearchResultListState> _searchTrendsKey = GlobalKey<TweetSearchResultListState>();

  @override
  Widget build(BuildContext context) {
    TwitterAccount.setCurrentContext(context);
    var subscriptionsModel = context.read<SubscriptionsModel>();

    var prefs = PrefService.of(context, listen: false);

    var defaultTheme = Theme.of(context);
    var searchTheme = defaultTheme.copyWith(
      appBarTheme: AppBarTheme(
        backgroundColor: defaultTheme.colorScheme.brightness == Brightness.dark ? Colors.grey[900] : Colors.white,
        iconTheme: defaultTheme.primaryIconTheme.copyWith(color: Colors.grey),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: InputBorder.none,
      ),
    );

    return Theme(
      data: searchTheme,
      child: Scaffold(
        appBar: AppBar(
          title: TextField(
            controller: _queryController,
            focusNode: _focusNode,
            style: searchTheme.textTheme.titleLarge,
            textInputAction: TextInputAction.search,
          ),
          actions: [
            IconButton(
                icon: const Icon(Symbols.close_rounded),
                onPressed: () {
                  _queryController.clear();
                  if (_searchUsersKey.currentState != null) {
                    _searchUsersKey.currentState!.resetQuery();
                  }
                  if (_searchTweetsKey.currentState != null) {
                    _searchTweetsKey.currentState!.resetQuery();
                  }
                  if (_searchTrendsKey.currentState != null) {
                    _searchTrendsKey.currentState!.resetQuery();
                  }
                }),
          ],
        ),
        body: Column(
          children: [
            MultiProvider(
              providers: [
                ChangeNotifierProvider<TweetContextState>(
                    create: (_) => TweetContextState(prefs.get(optionTweetsHideSensitive))),
                ChangeNotifierProvider<VideoContextState>(
                    create: (_) => VideoContextState(prefs.get(optionMediaDefaultMute))),
              ],
              child: Expanded(
                child: TweetSearchResultList<SearchTweetsModel, TweetWithCard>(
                    key: _searchTweetsKey,
                    queryController: _queryController,
                    store: context.read<SearchTweetsModel>(),
                    searchFunction: (q, c) => context.read<SearchTweetsModel>().searchTweets(
                        "from:${widget.screenName} $q", PrefService.of(context).get(optionEnhancedSearches),
                        cursor: c),
                    itemBuilder: (context, item) => TweetTile(tweet: item, clickable: true)),
              ),
            )
          ],
        ),
      ),
    );
  }
}

typedef ItemWidgetBuilder<T> = Widget Function(BuildContext context, T item);

class TweetSearchResultList<S extends Store<SearchStatus<T>>, T> extends StatefulWidget {
  final TextEditingController queryController;
  final S store;
  final Future<void> Function(String query, String? cursor) searchFunction;
  final ItemWidgetBuilder<T> itemBuilder;

  const TweetSearchResultList(
      {Key? key,
      required this.queryController,
      required this.store,
      required this.searchFunction,
      required this.itemBuilder})
      : super(key: key);

  @override
  State<TweetSearchResultList<S, T>> createState() => TweetSearchResultListState<S, T>();
}

class TweetSearchResultListState<S extends Store<SearchStatus<T>>, T> extends State<TweetSearchResultList<S, T>> {
  Timer? _debounce;
  String _previousQuery = '';
  String? _previousCursor;
  late PagingController<String?, T> _pagingController;
  late ScrollController _scrollController;
  double _lastOffset = 0;
  bool _inAppend = false;

  @override
  void initState() {
    super.initState();

    _previousQuery = '';
    _previousCursor = null;
    widget.queryController.addListener(() {
      String query = widget.queryController.text;
      if (query == _previousQuery) {
        return;
      }

      // If the current query is different from the last render's query, search
      if (_debounce?.isActive ?? false) {
        _debounce?.cancel();
      }

      // Debounce the search, so we don't make a request per keystroke
      _debounce = Timer(const Duration(milliseconds: 750), () async {
        fetchResults(null);
      });
    });

    _scrollController = ScrollController();
    _pagingController = PagingController(firstPageKey: null);
    _pagingController.addPageRequestListener((String? cursor) {
      fetchResults(cursor);
    });

    fetchResults(null);
  }

  @override
  void dispose() {
    super.dispose();
    _scrollController.dispose();
    _pagingController.dispose();
  }

  void resetQuery() {
    _scrollController.dispose();
    _pagingController.dispose();
    _previousQuery = '';
    _previousCursor = null;
    _lastOffset = 0;
    _scrollController = ScrollController();
    _pagingController = PagingController(firstPageKey: null);
    _pagingController.addPageRequestListener((String? cursor) {
      fetchResults(cursor);
    });
  }

  void fetchResults(String? cursor) {
    if (mounted) {
      String query = widget.queryController.text;
      if (query == _previousQuery && cursor == _previousCursor) {
        widget.searchFunction('', null);
        return;
      }
      _previousQuery = query;
      _previousCursor = cursor;
      widget.searchFunction(query, cursor);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScopedBuilder<S, SearchStatus<T>>.transition(
      store: widget.store,
      onLoading: (_) => const Center(child: CircularProgressIndicator()),
      onError: (_, error) => FullPageErrorWidget(
        error: error,
        stackTrace: null,
        prefix: L10n.of(context).unable_to_load_the_search_results,
        onRetry: () => fetchResults(_previousCursor),
      ),
      onState: (_, state) {
        if (state.items.isEmpty) {
          return Center(child: Text(L10n.of(context).no_results));
        }

        if (_previousQuery.isNotEmpty) {
          _inAppend = true;
          _pagingController.appendPage(state.items, state.cursorBottom);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _scrollController.jumpTo(_lastOffset);
            _inAppend = false;
          });
        }

        return PagedListView<String?, T>(
            scrollController: _scrollController,
            pagingController: _pagingController,
            addAutomaticKeepAlives: false,
            builderDelegate: PagedChildBuilderDelegate(itemBuilder: (context, elm, index) {
              if (!_inAppend) {
                _lastOffset = _scrollController.offset;
              }
              return widget.itemBuilder(context, elm);
            }));
      },
    );
  }
}
