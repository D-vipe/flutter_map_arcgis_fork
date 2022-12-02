import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_map/plugin_api.dart';
import 'package:collection/collection.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:latlong2/latlong.dart';
import 'arcgis_layer_options.dart';
import 'package:tuple/tuple.dart';
import 'package:flutter_map_arcgis/utils/util.dart' as util;
import 'package:dio/dio.dart';
import 'dart:convert';
import 'dart:async';

class ArcGisLayerWrapper extends StatelessWidget {
  final ArcGISLayerOptions options;
  final Stream stream;
  final bool clusterMarkers;
  final Color? clusterColor;
  final int? maxClusterRadius;
  final Size? clusterIconSize;

  const ArcGisLayerWrapper({
    Key? key,
    required this.options,
    required this.stream,
    this.clusterMarkers = false,
    this.clusterColor,
    this.maxClusterRadius,
    this.clusterIconSize,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final map = FlutterMapState.maybeOf(context)!;

    return _ArcGISLayer(
      mapState: map,
      options: options,
      clusterMarkers: clusterMarkers,
      clusterColor: clusterColor,
      maxClusterRadius: maxClusterRadius,
      clusterIconSize: clusterIconSize,
      stream: stream,
    );
  }
}

class _ArcGISLayer extends StatefulWidget {
  final FlutterMapState mapState;
  final ArcGISLayerOptions options;
  final bool clusterMarkers;
  final Color? clusterColor;
  final int? maxClusterRadius;
  final Size? clusterIconSize;
  final Stream stream;

  _ArcGISLayer({
    required this.options,
    required this.mapState,
    required this.stream,
    required this.clusterMarkers,
    this.clusterColor,
    this.maxClusterRadius,
    this.clusterIconSize,
  });

  @override
  State<StatefulWidget> createState() => __ArcGISLayerState();
}

class __ArcGISLayerState extends State<_ArcGISLayer> {
  FlutterMapState get _mapState => widget.mapState;

  List<dynamic> featuresPre = <dynamic>[];
  List<dynamic> features = <dynamic>[];

  StreamSubscription? _moveSub;

  var timer = Timer(Duration(milliseconds: 100), () => {});

  bool isMoving = false;

  final Map<String, Tile> _tiles = {};
  Tuple2<double, double>? _wrapX;
  Tuple2<double, double>? _wrapY;
  double? _tileZoom;

  Bounds? _globalTileRange;
  LatLngBounds? currentBounds;
  int activeRequests = 0;
  int targetRequests = 0;

  @override
  initState() {
    super.initState();
    _resetView();
    _moveSub = widget.stream.listen((_) => _handleMove());
  }

  @override
  void dispose() {
    super.dispose();
    featuresPre = <dynamic>[];
    features = <dynamic>[];
    _moveSub?.cancel();
  }

  void _handleMove() {
    setState(() {
      if (isMoving) {
        timer.cancel();
      }

      isMoving = true;
      timer = Timer(Duration(milliseconds: 200), () {
        isMoving = false;
        _resetView();
      });
    });
  }

  void _resetView() async {
    LatLngBounds mapBounds = _mapState.bounds;
    if (currentBounds == null) {
      await doResetView(mapBounds);
    } else {
      if (currentBounds!.southEast != mapBounds.southEast ||
          currentBounds!.southWest != mapBounds.southWest ||
          currentBounds!.northEast != mapBounds.northEast ||
          currentBounds!.northWest != mapBounds.northWest) {
        await doResetView(mapBounds);
      }
    }
  }

  Future doResetView(LatLngBounds mapBounds) async {
    setState(() {
      featuresPre = <dynamic>[];
      currentBounds = mapBounds;
    });
    _setView(_mapState.center, _mapState.zoom);
    _resetGrid();
    await genrateVirtualGrids();
  }

  void _setView(LatLng center, double zoom) {
    var tileZoom = _clampZoom(zoom.round().toDouble());
    if (_tileZoom != tileZoom) {
      _tileZoom = tileZoom;
    }
  }

  Bounds _pxBoundsToTileRange(Bounds bounds) {
    var tileSize = CustomPoint(256.0, 256.0);
    return Bounds(
      bounds.min.unscaleBy(tileSize).floor(),
      bounds.max.unscaleBy(tileSize).ceil() - CustomPoint(1, 1),
    );
  }

  double _clampZoom(double zoom) {
    // todo
    return zoom;
  }

  Coords _wrapCoords(Coords coords) {
    var newCoords = Coords(
      _wrapX != null ? util.wrapNum(coords.x.toDouble(), _wrapX!) : coords.x.toDouble(),
      _wrapY != null ? util.wrapNum(coords.y.toDouble(), _wrapY!) : coords.y.toDouble(),
    );
    newCoords.z = coords.z.toDouble();
    return newCoords;
  }

  bool _boundsContainsMarker(Marker marker) {
    var pxPoint = _mapState.project(marker.point);

    // See if any portion of the Marker rect resides in the map bounds
    // If not, don't spend any resources on build function.
    // This calculation works for any Anchor position whithin the Marker
    // Note that Anchor coordinates of (0,0) are at bottom-right of the Marker
    // unlike the map coordinates.
    final rightPortion = marker.width - marker.anchor.left;
    final leftPortion = marker.anchor.left;
    final bottomPortion = marker.height - marker.anchor.top;
    final topPortion = marker.anchor.top;

    final sw = CustomPoint(pxPoint.x + leftPortion, pxPoint.y - bottomPortion);
    final ne = CustomPoint(pxPoint.x - rightPortion, pxPoint.y + topPortion);

    return _mapState.pixelBounds.containsPartialBounds(Bounds(sw, ne));
  }

  Bounds _getTiledPixelBounds(LatLng center) {
    return _mapState.getPixelBounds(_tileZoom!);
  }

  void _resetGrid() {
    var map = _mapState;
    var crs = map.options.crs;
    var tileZoom = _tileZoom;

    var bounds = map.getPixelWorldBounds(_tileZoom);
    if (bounds != null) {
      _globalTileRange = _pxBoundsToTileRange(bounds);
    }

    // wrapping
    _wrapX = crs.wrapLng;
    if (_wrapX != null) {
      var first = (map.project(LatLng(0.0, crs.wrapLng!.item1), tileZoom).x / 256.0).floor().toDouble();
      var second = (map.project(LatLng(0.0, crs.wrapLng!.item2), tileZoom).x / 256.0).ceil().toDouble();
      _wrapX = Tuple2(first, second);
    }

    _wrapY = crs.wrapLat;
    if (_wrapY != null) {
      var first = (map.project(LatLng(crs.wrapLat!.item1, 0.0), tileZoom).y / 256.0).floor().toDouble();
      var second = (map.project(LatLng(crs.wrapLat!.item2, 0.0), tileZoom).y / 256.0).ceil().toDouble();
      _wrapY = Tuple2(first, second);
    }
  }

  Future genrateVirtualGrids() async {
    if (widget.options.geometryType == "point") {
      /// This generates way too many requests in a que. Either we need
      /// to limit the que or try not to use it at all
      if (_tileZoom! <= 14) {
        // var pixelBounds = _getTiledPixelBounds(_mapState.center);
        // var tileRange = _pxBoundsToTileRange(pixelBounds);

        // var queue = <Coords>[];

        // mark tiles as out of view...
        // for (var key in _tiles.keys) {
        //   var c = _tiles[key]!.coords;
        //   if (c.z != _tileZoom) {
        //     _tiles[key]!.current = false;
        //   }
        // }

        // for (var j = tileRange.min.y; j <= tileRange.max.y; j++) {
        //   for (var i = tileRange.min.x; i <= tileRange.max.x; i++) {
        //     var coords = Coords(i.toDouble(), j.toDouble());
        //     coords.z = _tileZoom!;

        //     if (!_isValidTile(coords)) {
        //       continue;
        //     }
        //     // Add all valid tiles to the queue on Flutter
        //     queue.add(coords);
        //   }
        // }

        // if (queue.isNotEmpty) {
        //   targetRequests = queue.length;
        //   activeRequests = 0;
        //   for (var i = 0; i < queue.length; i++) {
        //     var coordsNew = _wrapCoords(queue[i]);

        //     var bounds = coordsToBounds(coordsNew);
        //     await requestFeatures(bounds);
        //   }
        // }

        targetRequests = 1;
        activeRequests = 1;
        await requestFeatures(_mapState.bounds);
      } else {
        targetRequests = 1;
        activeRequests = 1;
        await requestFeatures(_mapState.bounds);
      }
    } else {
      targetRequests = 1;
      activeRequests = 1;
      await requestFeatures(_mapState.bounds);
    }
    targetRequests = 1;
    activeRequests = 1;
    await requestFeatures(_mapState.bounds);
  }

  LatLngBounds coordsToBounds(Coords coords) {
    var map = _mapState;
    var cellSize = 256.0;
    var nwPoint = coords.multiplyBy(cellSize);
    var sePoint = CustomPoint(nwPoint.x + cellSize, nwPoint.y + cellSize);
    var nw = map.unproject(nwPoint, coords.z.toDouble());
    var se = map.unproject(sePoint, coords.z.toDouble());
    return LatLngBounds(nw, se);
  }

  bool _isValidTile(Coords coords) {
    var crs = _mapState.options.crs;
    if (!crs.infinite) {
      var bounds = _globalTileRange;
      if ((crs.wrapLng == null && (coords.x < bounds!.min.x || coords.x > bounds.max.x)) || (crs.wrapLat == null && (coords.y < bounds!.min.y || coords.y > bounds.max.y))) {
        return false;
      }
    }
    return true;
  }

  Future requestFeatures(LatLngBounds bounds) async {
    debugPrint('FEATURES REQUESTED');
    try {
      String bounds_ = '"xmin":${bounds.southWest!.longitude},"ymin":${bounds.southWest!.latitude},"xmax":${bounds.northEast!.longitude},"ymax":${bounds.northEast?.latitude}';

      String url =
          '${widget.options.url}/query?f=json&geometry={"spatialReference":{"wkid":4326},$bounds_}&maxRecordCountFactor=30&outFields=*&outSR=4326&returnExceededLimitFeatures=true&spatialRel=esriSpatialRelIntersects&where=1=1&geometryType=esriGeometryEnvelope';

      Response response = await Dio().get(url);

      var features_ = <dynamic>[];

      var jsonData = response.data;
      if (jsonData is String) {
        jsonData = jsonDecode(jsonData);
      }

      if (jsonData["features"] != null) {
        for (var feature in jsonData["features"]) {
          if (widget.options.geometryType == "point") {
            var render = widget.options.render!(feature["attributes"]);

            if (render != null) {
              var latLng = LatLng(feature["geometry"]["y"].toDouble(), feature["geometry"]["x"].toDouble());

              features_.add(Marker(
                width: render.width,
                height: render.height,
                point: latLng,
                builder: (ctx) => Container(
                    child: GestureDetector(
                  onTap: () {
                    widget.options.onTap!(feature["attributes"], latLng);
                  },
                  child: render.builder,
                )),
              ));
            }
          } else if (widget.options.geometryType == "polygon") {
            for (var ring in feature["geometry"]["rings"]) {
              var points = <LatLng>[];

              for (var point_ in ring) {
                points.add(LatLng(point_[1].toDouble(), point_[0].toDouble()));
              }

              var render = widget.options.render!(feature["attributes"]);

              if (render != null) {
                features_.add(PolygonEsri(
                  points: points,
                  borderStrokeWidth: render.borderStrokeWidth,
                  color: render.color,
                  borderColor: render.borderColor,
                  isDotted: render.isDotted,
                  isFilled: render.isFilled,
                  attributes: feature["attributes"],
                ));
              }
            }
          } else if (widget.options.geometryType == "polyline") {
            for (var ring in feature["geometry"]["paths"]) {
              var points = <LatLng>[];

              for (var point_ in ring) {
                points.add(LatLng(point_[1].toDouble(), point_[0].toDouble()));
              }

              var render = widget.options.render!(feature["attributes"]);

              if (render != null) {
                features_.add(PolyLineEsri(
                  points: points,
                  borderStrokeWidth: render.borderStrokeWidth,
                  color: render.color,
                  borderColor: render.borderColor,
                  isDotted: render.isDotted,
                  attributes: feature["attributes"],
                ));
              }
            }
          }
        }

        activeRequests++;

        if (activeRequests >= targetRequests) {
          setState(() {
            features = [...featuresPre, ...features_];
            featuresPre = <Marker>[];
          });
        } else {
          setState(() {
            features = [...features, ...features_];
            featuresPre = [...featuresPre, ...features_];
          });
        }
      }
    } catch (e) {
      print(e);
    }
  }

  void findTapedPolygon(LatLng position) {
    for (var polygon in features) {
      var isInclude = _pointInPolygon(position, polygon.points);
      if (isInclude) {
        widget.options.onTap!(polygon.attributes, position);
      } else {
        widget.options.onTap!(null, position);
      }
    }
  }

  LatLng _offsetToCrs(Offset offset) {
    // Get the widget's offset
    var renderObject = context.findRenderObject() as RenderBox;
    var width = renderObject.size.width;
    var height = renderObject.size.height;

    // convert the point to global coordinates
    var localPoint = _offsetToPoint(offset);
    var localPointCenterDistance = CustomPoint((width / 2) - localPoint.x, (height / 2) - localPoint.y);
    var mapCenter = _mapState.project(_mapState.center);
    var point = mapCenter - localPointCenterDistance;
    return _mapState.unproject(point);
  }

  CustomPoint _offsetToPoint(Offset offset) {
    return CustomPoint(offset.dx, offset.dy);
  }

  void _fillOffsets(final List<Offset> offsets, final List<LatLng> points) {
    final len = points.length;
    for (var i = 0; i < len; ++i) {
      final point = points[i];
      final offset = _mapState.getOffsetFromOrigin(point);
      offsets.add(offset);
    }
  }

  @override
  Widget build(BuildContext context) {
    final map = FlutterMapState.maybeOf(context)!;

    if (widget.options.geometryType == "point") {
      return StreamBuilder<void>(
        stream: widget.stream,
        builder: (BuildContext context, _) {
          return _buildMarkers(context);
        },
      );
    } else if (widget.options.geometryType == "polyline") {
      return StreamBuilder<void>(
        stream: widget.stream,
        builder: (BuildContext context, _) {
          return LayoutBuilder(
            builder: (BuildContext context, BoxConstraints bc) {
              // TODO unused BoxContraints should remove?
              final size = Size(bc.maxWidth, bc.maxHeight);
              return _buildPolygonLines(context, size);
            },
          );
        },
      );
    } else {
      return StreamBuilder<void>(
        stream: widget.stream,
        builder: (BuildContext context, _) {
          return LayoutBuilder(
            builder: (BuildContext context, BoxConstraints bc) {
              // TODO unused BoxContraints should remove?
              final size = Size(bc.maxWidth, bc.maxHeight);
              return _buildPolygons(context, size);
            },
          );
        },
      );
    }
  }

  Widget _buildMarkers(BuildContext context) {
    List<Widget> elements = [];
    List<Marker> markers = [];
    if (features.isNotEmpty) {
      for (var markerOpt in features) {
        if (!(markerOpt is PolygonEsri)) {
          // Find the position of the point on the screen
          var pos = _mapState.project(markerOpt.point);

          // Consider zoom scale
          pos = pos.multiplyBy(_mapState.getZoomScale(_mapState.zoom, _mapState.zoom)) - _mapState.pixelOrigin;

          var pixelPosX = (pos.x - (markerOpt.width - markerOpt.anchor.left)).toDouble();
          var pixelPosY = (pos.y - (markerOpt.height - markerOpt.anchor.top)).toDouble();

          if (!_boundsContainsMarker(markerOpt)) {
            continue;
          }

          if (widget.clusterMarkers) {
            markers.add(markerOpt);
          } else {
            elements.add(
              Positioned(
                width: markerOpt.width,
                height: markerOpt.height,
                left: pixelPosX,
                top: pixelPosY,
                child: markerOpt.builder(context),
              ),
            );
          }
        }
      }
    }

    return widget.clusterMarkers
        ? MarkerClusterLayerWidget(
            options: MarkerClusterLayerOptions(
              maxClusterRadius: widget.maxClusterRadius ?? 45,
              size: widget.clusterIconSize ?? Size(30, 30),
              anchor: AnchorPos.align(AnchorAlign.center),
              fitBoundsOptions: FitBoundsOptions(
                padding: _mapState.zoom <= 11 ? EdgeInsets.all(50) : EdgeInsets.all(30),
                maxZoom: 15,
              ),
              markers: markers,
              builder: (context, markers) {
                return Container(
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), color: widget.clusterColor ?? Colors.blue),
                  child: Center(
                    child: Text(
                      markers.length.toString(),
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                );
              },
            ),
          )
        : Container(
            child: Stack(
              children: elements,
            ),
          );
  }

  Widget _buildPolygons(BuildContext context, Size size) {
    var elements = <Widget>[];
    if (features.isNotEmpty) {
      for (var polygon in features) {
        if (polygon is PolygonEsri) {
          polygon.offsets.clear();

          // Copied from flutter_map polygon_layer builder
          if (null != polygon.holeOffsetsList) {
            for (final offsets in polygon.holeOffsetsList!) {
              offsets.clear();
            }
          }

          /// This is copied from flutter_map polygon_layer builder
          /// consider adding param to ArcGISLayerWrapper to control this feature
          if (!polygon.boundingBox.isOverlapping(_mapState.bounds)) {
            // skip this polygon as it's offscreen
            continue;
          }

          _fillOffsets(polygon.offsets, polygon.points);

          if (null != polygon.holePointsList) {
            final len = polygon.holePointsList!.length;
            for (var i = 0; i < len; ++i) {
              _fillOffsets(polygon.holeOffsetsList![i], polygon.holePointsList![i]);
            }
          }

          var i = 0;

          for (var point in polygon.points) {
            var pos = _mapState.project(point);
            pos = pos.multiplyBy(_mapState.getZoomScale(_mapState.zoom, _mapState.zoom)) - _mapState.pixelOrigin;
            polygon.offsets.add(Offset(pos.x.toDouble(), pos.y.toDouble()));
            if (i > 0 && i < polygon.points.length) {
              polygon.offsets.add(Offset(pos.x.toDouble(), pos.y.toDouble()));
            }
            i++;
          }

          elements.add(
            GestureDetector(
                onTapUp: (details) {
                  RenderBox box = context.findRenderObject() as RenderBox;
                  final offset = box.globalToLocal(details.globalPosition);

                  var latLng = _offsetToCrs(offset);
                  findTapedPolygon(latLng);
                },
                child: CustomPaint(
                  painter: PolygonPainter(polygon, 0.0),
                  size: size,
                )),
          );
        }
      }
    }

    return Container(
      child: Stack(
        children: elements,
      ),
    );
  }

  Widget _buildPolygonLines(BuildContext context, Size size) {
    var elements = <Widget>[];

    if (features.isNotEmpty) {
      for (var polyLine in features) {
        if (polyLine is PolyLineEsri) {
          polyLine.offsets.clear();

          // consider adding bool param to control this block
          if (!polyLine.boundingBox.isOverlapping(_mapState.bounds)) {
            // skip this polyline as it's offscreen
            continue;
          }

          _fillOffsets(polyLine.offsets, polyLine.points);

          var i = 0;

          for (var point in polyLine.points) {
            var pos = _mapState.project(point);
            pos = pos.multiplyBy(_mapState.getZoomScale(_mapState.zoom, _mapState.zoom)) - _mapState.pixelOrigin;
            polyLine.offsets.add(Offset(pos.x.toDouble(), pos.y.toDouble()));
            if (i > 0 && i < polyLine.points.length) {
              polyLine.offsets.add(Offset(pos.x.toDouble(), pos.y.toDouble()));
            }
            i++;
          }

          elements.add(
            GestureDetector(
                onTapUp: (details) {
                  RenderBox box = context.findRenderObject() as RenderBox;
                  final offset = box.globalToLocal(details.globalPosition);

                  var latLng = _offsetToCrs(offset);
                  findTapedPolygon(latLng);
                },
                child: CustomPaint(
                  painter: PolylinePainter(polyLine, false),
                  size: size,
                )),
          );
        }
      }
    }

    return Container(
      child: Stack(
        children: elements,
      ),
    );
  }
}

class PolygonEsri extends Polygon {
  final List<LatLng> points;
  final List<Offset> offsets = [];
  final Color color;
  final double borderStrokeWidth;
  final Color borderColor;
  final bool isDotted;
  final bool isFilled;
  final dynamic attributes;
  late final LatLngBounds boundingBox;

  PolygonEsri({
    required this.points,
    this.color = const Color(0xFF00FF00),
    this.borderStrokeWidth = 0.0,
    this.borderColor = const Color(0xFFFFFF00),
    this.isDotted = false,
    this.isFilled = false,
    this.attributes,
  }) : super(points: points) {
    boundingBox = LatLngBounds.fromPoints(points);
  }
}

class PolyLineEsri extends Polyline {
  final List<LatLng> points;
  final List<Offset> offsets = [];
  final Color color;
  final double borderStrokeWidth;
  final Color borderColor;
  final bool isDotted;
  final dynamic attributes;
  late final LatLngBounds boundingBox;

  PolyLineEsri({
    required this.points,
    this.color = const Color(0xFF00FF00),
    this.borderStrokeWidth = 0.0,
    this.borderColor = const Color(0xFFFFFF00),
    this.isDotted = false,
    this.attributes,
  }) : super(points: points) {
    boundingBox = LatLngBounds.fromPoints(points);
  }
}

bool _pointInPolygon(LatLng position, List<LatLng> points) {
  // Check if the point sits exactly on a vertex
  // var vertexPosition = points.firstWhere((point) => point == position, orElse: () => null);
  LatLng? vertexPosition = points.firstWhereOrNull((point) => point == position);
  if (vertexPosition != null) {
    return true;
  }

  // Check if the point is inside the polygon or on the boundary
  int intersections = 0;
  var verticesCount = points.length;

  for (int i = 1; i < verticesCount; i++) {
    LatLng vertex1 = points[i - 1];
    LatLng vertex2 = points[i];

    // Check if point is on an horizontal polygon boundary
    if (vertex1.latitude == vertex2.latitude &&
        vertex1.latitude == position.latitude &&
        position.longitude > min(vertex1.longitude, vertex2.longitude) &&
        position.longitude < max(vertex1.longitude, vertex2.longitude)) {
      return true;
    }

    if (position.latitude > min(vertex1.latitude, vertex2.latitude) &&
        position.latitude <= max(vertex1.latitude, vertex2.latitude) &&
        position.longitude <= max(vertex1.longitude, vertex2.longitude) &&
        vertex1.latitude != vertex2.latitude) {
      var xinters = (position.latitude - vertex1.latitude) * (vertex2.longitude - vertex1.longitude) / (vertex2.latitude - vertex1.latitude) + vertex1.longitude;
      if (xinters == position.longitude) {
        // Check if point is on the polygon boundary (other than horizontal)
        return true;
      }
      if (vertex1.longitude == vertex2.longitude || position.longitude <= xinters) {
        intersections++;
      }
    }
  }

  // If the number of edges we passed through is odd, then it's in the polygon.
  return intersections % 2 != 0;
}
