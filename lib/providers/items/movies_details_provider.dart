import 'dart:async';
import 'dart:developer';

import 'package:chopper/chopper.dart';
import 'package:logging/logging.dart' as logging;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/models/items/movie_model.dart';
import 'package:fladder/models/items/special_feature_model.dart';
import 'package:fladder/models/seerr/seerr_dashboard_model.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/related_provider.dart';
import 'package:fladder/providers/seerr_api_provider.dart';
import 'package:fladder/providers/service_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/seerr/seerr_models.dart';
import 'package:fladder/util/item_base_model/item_base_model_extensions.dart';

part 'movies_details_provider.g.dart';

@riverpod
class MovieDetails extends _$MovieDetails {
  late final JellyService api = ref.read(jellyApiProvider);

  @override
  MovieModel? build(String arg) => null;

  Future<Response?> fetchDetails(ItemBaseModel item) async {
    try {
      if (item is MovieModel) {
        state = state ?? item;
      }
      MovieModel? newState;
      final response = await api.usersUserIdItemsItemIdGet(itemId: item.id);
      if (response.body == null) return null;
      newState = (response.bodyOrThrow as MovieModel).copyWith(
        related: state?.related ?? const [],
        seerrRelated: state?.seerrRelated ?? const [],
        seerrRecommended: state?.seerrRecommended ?? const [],
      );

      state = newState;

      List<BaseItemDto> specialFeatures;
      try {
        specialFeatures = (await api.itemsItemIdSpecialFeaturesGet(itemId: item.id)).body ?? [];
      } on Exception catch (e, s) {
        specialFeatures = [];
        log("Failed to get special features for movie id ${item.id} due to $e",
            level: logging.Level.WARNING.value, error: e, stackTrace: s);
      }

      final related = await ref.read(relatedUtilityProvider).relatedContent(item.id);
      final List<SpecialFeatureModel> specialFeatureModel =
          SpecialFeatureModel.specialFeaturesFromDto(specialFeatures, ref).toList();

      List<SeerrDashboardPosterModel> seerrRelated = const [];
      List<SeerrDashboardPosterModel> seerrRecommended = const [];

      String? seerrUrl;

      final seerrCreds = ref.read(userProvider)?.seerrCredentials;
      if (seerrCreds?.isConfigured == true) {
        final tmdbId = newState.tmdbId;
        if (tmdbId != null) {
          final seerr = ref.read(seerrApiProvider);
          seerrRelated = await seerr.discoverRelatedMovies(tmdbId: tmdbId);
          seerrRecommended = await seerr.discoverRecommendedMovies(tmdbId: tmdbId);
          final seerrPoster = await seerr.fetchDashboardPosterFromIds(
            tmdbId: tmdbId,
            mediaType: SeerrMediaType.movie,
          );
          final status = seerrPoster?.mediaInfo?.mediaStatus;
          if (status != SeerrMediaStatus.unknown) {
            final seerrServerUrl = ref.read(userProvider.select((value) => value?.seerrCredentials?.serverUrl));
            seerrUrl = '${seerrServerUrl}movie/$tmdbId';
          }
        }
      }

      state = newState.copyWith(
          related: related.body,
          seerrRelated: seerrRelated,
          seerrRecommended: seerrRecommended,
          overview: state?.overview.copyWith(
            seerrUrl: seerrUrl,
          ),
          specialFeatures: specialFeatureModel);

      unawaited(_waitForRemoteVersions(item.id, newState.path));
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Gelato (Stremio addons in Jellyfin) only looks up the versions of a streamed movie the
  /// first time it is opened, which can take several seconds. Keep asking the server for the
  /// item until its versions show up, so the version picker appears without a manual refresh.
  Future<void> _waitForRemoteVersions(String itemId, String? path) async {
    // Local files have a plain file path; Gelato items use gelato:// stubs, stream URLs or
    // stub files under the Gelato library folders.
    final lower = path?.toLowerCase() ?? '';
    final isRemote = lower.isEmpty ||
        lower.contains('gelato') ||
        lower.startsWith('http') ||
        lower.contains('stub') ||
        lower.contains('tmdb:');
    if (!isRemote) return;

    for (var attempt = 0; attempt < 15; attempt++) {
      try {
        if ((state?.mediaStreams.versionStreams.length ?? 0) > 1) return;
        await Future.delayed(const Duration(seconds: 2));
        final response = await api.usersUserIdItemsItemIdGet(itemId: itemId);
        final refreshed = response.body as MovieModel?;
        if (refreshed == null) continue;
        final current = state;
        if (current == null) return;
        if (refreshed.mediaStreams.versionStreams.length > current.mediaStreams.versionStreams.length) {
          state = current.copyWith(mediaStreams: refreshed.mediaStreams);
        }
      } catch (e) {
        log("Waiting for Gelato versions of $itemId failed: $e", level: logging.Level.WARNING.value);
        return;
      }
    }
  }

  void setMediaStreamHelper(MediaStreamsModel changed) {
    state = state?.copyWith(mediaStreams: changed);
  }
}
