import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:intl/intl.dart';

import '../../../constants/hive_constants.dart';
import '../../../data/inspection_storage_model.dart';
import '../../../hive_registrar.g.dart';
import '../../../models/inspection_stats_model.dart';
import '../../../models/local_inspection.dart';
import '../../../providers/connectivity_provider.dart';
import '../../../providers/inspection_provider.dart';
import '../../../providers/stats_provider.dart';
import '../../../routes/routes.dart';
import '../../../services/app_update_service.dart';
import '../../../services/notification_service.dart';
import '../../../utils/network_error_helper.dart';
import '../../attendance/attendance_screen.dart';
import '../../work_assigned/work_assigned_screen.dart';
import '../reports_page.dart';
import 'car_spy_data.dart';
import 'widgets/car_spy_bottom_nav_bar.dart';
import 'widgets/car_spy_hero_section.dart';
import 'widgets/car_spy_top_app_bar.dart';

class CarSpyHome extends ConsumerStatefulWidget {
  final int initialIndex;

  const CarSpyHome({super.key, this.initialIndex = 0});

  @override
  ConsumerState<CarSpyHome> createState() => _CarSpyHomeState();
}

class _CarSpyHomeState extends ConsumerState<CarSpyHome> {
  late int _selectedIndex;
  int _selectedChartTab = 0; // 0 = daily, 1 = monthly
  Box<InspectionStorageModel>? _inspectionBox;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.initialIndex;
    _initHive();
    // Now that the inspector is authenticated and a resumed Activity exists,
    // make sure notification permission is granted (a prompt dismissed during
    // cold launch gets a reliable second chance here), then register this
    // device's FCM token with the backend. Both fire-and-forget.
    NotificationService.ensurePermission()
        .then((_) => NotificationService.syncToken());
    // A notification tap may have requested a specific tab — honour it, and keep
    // listening while this shell is alive.
    NotificationService.requestedTab.addListener(_onTabRequested);
    _onTabRequested();
    // Check for a Play Store update once the home screen is up (Android-only;
    // fire-and-forget, never blocks or disrupts the user).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      const AppUpdateService().checkForUpdate();
    });
  }

  /// Switch to the tab a notification tap asked for (if any).
  void _onTabRequested() {
    final index = NotificationService.takePendingTab();
    if (index != null && index >= 0 && index < carSpyBottomNavItems.length) {
      if (mounted) setState(() => _selectedIndex = index);
    }
  }

  @override
  void dispose() {
    NotificationService.requestedTab.removeListener(_onTabRequested);
    super.dispose();
  }

  Future<void> _initHive() async {
    try {
      if (!Hive.isBoxOpen(HiveConstants.INSPECTION_BOX)) {
        await Hive.initFlutter();

        if (!Hive.isAdapterRegistered(0)) {
          Hive.registerAdapters();
        }

        _inspectionBox = await Hive.openBox<InspectionStorageModel>(
          HiveConstants.INSPECTION_BOX,
        );
      } else {
        _inspectionBox =
            Hive.box<InspectionStorageModel>(HiveConstants.INSPECTION_BOX);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Error initializing inspection data')),
      );
    }
  }

  /// Matches [MainContent.hasExistingInspection]: draft with data, &lt; 24h.
  Future<bool> _hasExistingInspection() async {
    try {
      if (!Hive.isBoxOpen(HiveConstants.INSPECTION_BOX)) {
        _inspectionBox = await Hive.openBox<InspectionStorageModel>(
          HiveConstants.INSPECTION_BOX,
        );
      } else {
        _inspectionBox =
            Hive.box<InspectionStorageModel>(HiveConstants.INSPECTION_BOX);
      }

      final existingData =
          _inspectionBox?.get(HiveConstants.CURRENT_INSPECTION_KEY);

      if (existingData != null) {
        if (existingData.isCompleted ||
            existingData.status == 'submitted' ||
            existingData.status == 'offline') {
          return false;
        }

        final hasValidData = existingData.itemValues.isNotEmpty ||
            existingData.itemImages.isNotEmpty ||
            existingData.itemRemarks.isNotEmpty ||
            existingData.itemVideos.isNotEmpty ||
            existingData.itemAudios.isNotEmpty ||
            existingData.itemFiles.isNotEmpty ||
            (existingData.multiImages?.isNotEmpty ?? false);

        if (hasValidData) {
          final inspectionTime = existingData.timestamp;
          final currentTime = DateTime.now();
          final timeDifference = currentTime.difference(inspectionTime);
          return timeDifference.inHours < 24;
        }
      }
      return false;
    } catch (e) {
      debugPrint('Error checking existing inspection: $e');
      return false;
    }
  }

  Future<void> _clearSavedInspectionAndStartNew() async {
    try {
      if (_inspectionBox?.isOpen ?? false) {
        await _inspectionBox?.delete(HiveConstants.CURRENT_INSPECTION_KEY);
      } else if (Hive.isBoxOpen(HiveConstants.INSPECTION_BOX)) {
        await Hive.box<InspectionStorageModel>(HiveConstants.INSPECTION_BOX)
            .delete(HiveConstants.CURRENT_INSPECTION_KEY);
      }
      _navigateToInspection(true);
    } catch (e) {
      debugPrint('Error clearing inspection: $e');
      _navigateToInspection(true);
    }
  }

  Future<void> _handleInitializeScanTap() async {
    try {
      if (!mounted) return;

      // An inspection cannot be started offline, so fail fast with a clear
      // message instead of letting the user fill in a form that can't begin.
      // Reads the shared connectivity state — no extra reachability probe.
      if (!ref.read(connectivityStatusProvider)) {
        NetworkErrorHelper.showOfflineSnackBar(
          context,
          'Internet required to start the inspection.',
        );
        return;
      }

      final hasExisting = await _hasExistingInspection();
      if (!mounted) return;

      if (hasExisting) {
        _clearSavedInspectionAndStartNew();
      } else {
        _navigateToInspection(true);
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Error starting inspection. Please try again.'),
        ),
      );
    }
  }

  void _navigateToInspection(bool isNew) {
    if (isNew) {
      Navigator.pushNamed(
        context,
        Routes.vehicleDetails,
        arguments: {'isNew': isNew},
      ).then((_) {
        if (mounted) setState(() {});
      });
    } else {
      Navigator.pushNamed(
        context,
        Routes.inspection,
        arguments: {'isNew': isNew},
      ).then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  // ── Chart helpers ────────────────────────────────────────────────────────

  List<String> _getDayLabels() {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final now = DateTime.now();
    return List.generate(7, (i) {
      final day = now.subtract(Duration(days: 6 - i));
      return days[day.weekday - 1];
    });
  }

  List<String> _getMonthLabels() {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final now = DateTime.now();
    return List.generate(6, (i) {
      final m = DateTime(now.year, now.month - 5 + i);
      return months[(m.month - 1) % 12];
    });
  }

  List<FlSpot> _getDailySpots(List<LocalInspection> inspections) {
    final now = DateTime.now();
    return List.generate(7, (i) {
      final day = now.subtract(Duration(days: 6 - i));
      final count = inspections
          .where((insp) =>
              insp.createdAt.year == day.year &&
              insp.createdAt.month == day.month &&
              insp.createdAt.day == day.day)
          .length;
      return FlSpot(i.toDouble(), count.toDouble());
    });
  }

  List<FlSpot> _getMonthlySpots(List<LocalInspection> inspections) {
    final now = DateTime.now();
    return List.generate(6, (i) {
      final m = DateTime(now.year, now.month - 5 + i);
      final count = inspections
          .where((insp) =>
              insp.createdAt.year == m.year && insp.createdAt.month == m.month)
          .length;
      return FlSpot(i.toDouble(), count.toDouble());
    });
  }

  Widget _legendItem(String label, Color color) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: const TextStyle(
              fontSize: 11, color: CarSpyColors.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _buildChartTabButton(String label, int index) {
    final isSelected = _selectedChartTab == index;
    return GestureDetector(
      onTap: () => setState(() => _selectedChartTab = index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ]
              : [],
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
            color: isSelected
                ? CarSpyColors.onSurface
                : CarSpyColors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _buildChartStat(
      String label, String value, IconData icon, Color color) {
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: color, size: 18),
        ),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: CarSpyColors.onSurface,
                letterSpacing: -0.3,
              ),
            ),
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                color: CarSpyColors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildInspectionChart(
    List<LocalInspection> inspections,
    InspectionStats? dailyStats,
    InspectionStats? monthlyStats,
  ) {
    final isDaily = _selectedChartTab == 0;

    // Daily: use active API buckets (non-zero days).
    // Monthly: use all API monthly buckets so every month appears on the axis.
    final List<InspectionStatsBucket> apiBuckets;
    if (isDaily) {
      apiBuckets = dailyStats?.buckets ?? [];
    } else {
      apiBuckets = monthlyStats?.buckets ?? [];
    }
    final useApiData = apiBuckets.isNotEmpty;

    final List<FlSpot> spots;
    final List<String> labels;

    if (useApiData) {
      spots = apiBuckets
          .asMap()
          .entries
          .map((e) => FlSpot(e.key.toDouble(), e.value.total.toDouble()))
          .toList();
      if (isDaily) {
        // daily buckets: "2026-05-17" → show day "17"
        labels = apiBuckets.map((b) {
          final parts = b.bucket.split('-');
          return parts.length == 3 ? parts[2] : b.bucket;
        }).toList();
      } else {
        // monthly buckets: "2026-05" → show "May"
        const monthNames = [
          'Jan',
          'Feb',
          'Mar',
          'Apr',
          'May',
          'Jun',
          'Jul',
          'Aug',
          'Sep',
          'Oct',
          'Nov',
          'Dec',
        ];
        labels = apiBuckets.map((b) {
          final parts = b.bucket.split('-');
          final m = parts.length >= 2 ? (int.tryParse(parts[1]) ?? 1) : 1;
          return monthNames[(m - 1).clamp(0, 11)];
        }).toList();
      }
    } else if (isDaily) {
      spots = _getDailySpots(inspections);
      labels = _getDayLabels();
    } else {
      spots = _getMonthlySpots(inspections);
      labels = _getMonthLabels();
    }

    final rawMax = spots.map((s) => s.y).fold(0.0, (a, b) => a > b ? a : b);
    final chartMaxY = rawMax < 4 ? 4.0 : rawMax + 2;

    final int totalCount;
    final int todayCount;
    final String secondStatLabel;

    if (useApiData) {
      if (isDaily && dailyStats != null) {
        final todayStr = DateFormat('yyyy-MM-dd').format(DateTime.now());
        final todayBuckets =
            dailyStats.buckets.where((b) => b.bucket == todayStr);
        todayCount = todayBuckets.isEmpty ? 0 : todayBuckets.first.total;
        totalCount = dailyStats.totals.total;
        secondStatLabel = 'This Month';
      } else if (!isDaily && monthlyStats != null) {
        todayCount = spots.isNotEmpty ? spots.last.y.toInt() : 0;
        totalCount = monthlyStats.totals.total;
        secondStatLabel = '6 Months';
      } else {
        todayCount = spots.isNotEmpty ? spots.last.y.toInt() : 0;
        totalCount = spots.fold(0.0, (sum, s) => sum + s.y).toInt();
        secondStatLabel = isDaily ? 'This Week' : 'This Year (6m)';
      }
    } else {
      todayCount = spots.isNotEmpty ? spots.last.y.toInt() : 0;
      totalCount = spots.fold(0.0, (sum, s) => sum + s.y).toInt();
      secondStatLabel = isDaily ? 'This Week' : 'This Year (6m)';
    }

    return Container(
      decoration: BoxDecoration(
        color: CarSpyColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: CarSpyColors.outlineVariant.withValues(alpha: 0.6),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Inspections',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: CarSpyColors.onSurface,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    useApiData
                        ? (isDaily && dailyStats != null
                            ? DateFormat('MMMM yyyy').format(
                                DateFormat('yyyy-MM-dd').parse(dailyStats.from))
                            : 'Last 6 months')
                        : (isDaily ? 'Last 7 days' : 'Last 6 months'),
                    style: const TextStyle(
                      fontSize: 12,
                      color: CarSpyColors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.all(3),
                child: Row(
                  children: [
                    _buildChartTabButton('Daily', 0),
                    _buildChartTabButton('Monthly', 1),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          RepaintBoundary(
              child: SizedBox(
            height: 180,
            child: useApiData && isDaily
                ? ShaderMask(
                    shaderCallback: (rect) => const LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [Colors.white, Colors.white, Colors.transparent],
                      stops: [0.0, 0.82, 1.0],
                    ).createShader(rect),
                    blendMode: BlendMode.dstIn,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        width: apiBuckets.length * 28.0,
                        height: 180,
                        child: BarChart(
                          BarChartData(
                            maxY: chartMaxY,
                            alignment: BarChartAlignment.spaceAround,
                            barGroups: apiBuckets.asMap().entries.map((e) {
                              final i = e.key;
                              final b = e.value;
                              final approvedY = b.approved.toDouble();
                              final pendingY = approvedY + b.pending;
                              final totalY = b.total.toDouble();
                              return BarChartGroupData(
                                x: i,
                                barRods: [
                                  BarChartRodData(
                                    toY: totalY,
                                    color: Colors.transparent,
                                    width: 14,
                                    borderRadius: const BorderRadius.vertical(
                                        top: Radius.circular(4)),
                                    rodStackItems: [
                                      if (b.approved > 0)
                                        BarChartRodStackItem(0, approvedY,
                                            const Color(0xFF22C55E)),
                                      if (b.pending > 0)
                                        BarChartRodStackItem(approvedY,
                                            pendingY, const Color(0xFFF59E0B)),
                                      if (b.rejected > 0)
                                        BarChartRodStackItem(pendingY, totalY,
                                            const Color(0xFFEF4444)),
                                    ],
                                  ),
                                ],
                              );
                            }).toList(),
                            gridData: FlGridData(
                              show: true,
                              drawVerticalLine: false,
                              horizontalInterval: chartMaxY / 4,
                              getDrawingHorizontalLine: (_) => FlLine(
                                color: CarSpyColors.outlineVariant
                                    .withValues(alpha: 0.5),
                                strokeWidth: 1,
                              ),
                            ),
                            borderData: FlBorderData(show: false),
                            titlesData: FlTitlesData(
                              topTitles: const AxisTitles(
                                  sideTitles: SideTitles(showTitles: false)),
                              rightTitles: const AxisTitles(
                                  sideTitles: SideTitles(showTitles: false)),
                              leftTitles: AxisTitles(
                                sideTitles: SideTitles(
                                  showTitles: true,
                                  reservedSize: 30,
                                  interval: chartMaxY / 4,
                                  getTitlesWidget: (value, meta) {
                                    if (value == meta.max) {
                                      return const SizedBox.shrink();
                                    }
                                    return Text(
                                      value.toInt().toString(),
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: CarSpyColors.onSurfaceVariant,
                                      ),
                                    );
                                  },
                                ),
                              ),
                              bottomTitles: AxisTitles(
                                sideTitles: SideTitles(
                                  showTitles: true,
                                  reservedSize: 22,
                                  getTitlesWidget: (value, _) {
                                    final idx = value.toInt();
                                    if (idx < 0 || idx >= labels.length) {
                                      return const SizedBox.shrink();
                                    }
                                    return Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Text(
                                        labels[idx],
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: CarSpyColors.onSurfaceVariant,
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ),
                            barTouchData: BarTouchData(
                              touchTooltipData: BarTouchTooltipData(
                                getTooltipColor: (_) => const Color(0xFF1E293B),
                                tooltipRoundedRadius: 8,
                                fitInsideVertically: true,
                                fitInsideHorizontally: true,
                                tooltipPadding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 8),
                                getTooltipItem: (group, _, rod, __) {
                                  final b = apiBuckets[group.x];
                                  return BarTooltipItem(
                                    '${b.bucket.substring(5)}\n',
                                    const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 12,
                                    ),
                                    children: [
                                      if (b.approved > 0)
                                        TextSpan(
                                          text: 'Approved: ${b.approved}\n',
                                          style: const TextStyle(
                                              fontSize: 11,
                                              color: Color(0xFF86EFAC),
                                              fontWeight: FontWeight.normal),
                                        ),
                                      if (b.pending > 0)
                                        TextSpan(
                                          text: 'Pending: ${b.pending}\n',
                                          style: const TextStyle(
                                              fontSize: 11,
                                              color: Color(0xFFFCD34D),
                                              fontWeight: FontWeight.normal),
                                        ),
                                      if (b.rejected > 0)
                                        TextSpan(
                                          text: 'Rejected: ${b.rejected}',
                                          style: const TextStyle(
                                              fontSize: 11,
                                              color: Color(0xFFFCA5A5),
                                              fontWeight: FontWeight.normal),
                                        ),
                                      if (b.total == 0)
                                        const TextSpan(
                                          text: 'No inspections',
                                          style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.normal),
                                        ),
                                    ],
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  )
                : LineChart(
                    LineChartData(
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        horizontalInterval: chartMaxY / 4,
                        getDrawingHorizontalLine: (_) => FlLine(
                          color: CarSpyColors.outlineVariant
                              .withValues(alpha: 0.5),
                          strokeWidth: 1,
                        ),
                      ),
                      titlesData: FlTitlesData(
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            interval: chartMaxY / 4,
                            reservedSize: 30,
                            getTitlesWidget: (value, meta) {
                              if (value == meta.max) {
                                return const SizedBox.shrink();
                              }
                              return Text(
                                value.toInt().toString(),
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: CarSpyColors.onSurfaceVariant,
                                ),
                              );
                            },
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            interval: 1,
                            getTitlesWidget: (value, meta) {
                              final idx = value.toInt();
                              if (idx < 0 || idx >= labels.length) {
                                return const SizedBox.shrink();
                              }
                              return Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  labels[idx],
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: CarSpyColors.onSurfaceVariant,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        rightTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        topTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                      ),
                      borderData: FlBorderData(show: false),
                      minX: 0,
                      maxX: (labels.length - 1).toDouble(),
                      minY: 0,
                      maxY: chartMaxY,
                      lineBarsData: [
                        LineChartBarData(
                          spots: spots,
                          isCurved: true,
                          color: CarSpyColors.primary,
                          barWidth: 2.5,
                          isStrokeCapRound: true,
                          dotData: FlDotData(
                            show: true,
                            getDotPainter: (spot, percent, barData, index) =>
                                FlDotCirclePainter(
                              radius: 4,
                              color: Colors.white,
                              strokeWidth: 2,
                              strokeColor: CarSpyColors.primary,
                            ),
                          ),
                          belowBarData: BarAreaData(
                            show: true,
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                CarSpyColors.primary.withValues(alpha: 0.18),
                                CarSpyColors.primary.withValues(alpha: 0.0),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
          )),
          if (useApiData && isDaily) ...[
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    _legendItem('Approved', const Color(0xFF22C55E)),
                    const SizedBox(width: 12),
                    _legendItem('Pending', const Color(0xFFF59E0B)),
                    const SizedBox(width: 12),
                    _legendItem('Rejected', const Color(0xFFEF4444)),
                  ],
                ),
                Row(
                  children: [
                    Icon(
                      Icons.swipe_rounded,
                      size: 13,
                      color:
                          CarSpyColors.onSurfaceVariant.withValues(alpha: 0.6),
                    ),
                    const SizedBox(width: 3),
                    Text(
                      'Swipe',
                      style: TextStyle(
                        fontSize: 11,
                        color: CarSpyColors.onSurfaceVariant
                            .withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: _buildChartStat(
                  'Today',
                  todayCount.toString(),
                  Icons.today_outlined,
                  CarSpyColors.primary,
                ),
              ),
              Expanded(
                child: _buildChartStat(
                  secondStatLabel,
                  totalCount.toString(),
                  Icons.bar_chart_rounded,
                  const Color(0xFF6366F1),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHomeTab() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          CarSpyHeroSection(
            onInitializeScan: _handleInitializeScanTap,
          ),
          const SizedBox(height: 28),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _buildInspectionChart(
              ref.watch(inspectionProvider.select((s) => s.inspections)),
              ref.watch(inspectionStatsProvider).value,
              ref.watch(monthlyInspectionStatsProvider).value,
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // One connectivity source drives the whole screen: when it drops we surface
    // the offline snackbar; when it is restored we refresh the dashboard data
    // at once. This single listener replaces any per-screen polling.
    ref.listen(connectivityStatusProvider, (previous, next) {
      if (!next) {
        NetworkErrorHelper.showOfflineSnackBar(
          context,
          NetworkErrorHelper.offlineMessage,
          onRetry: () =>
              ref.read(connectivityStatusProvider.notifier).refresh(),
        );
      } else if (previous == false) {
        ref.invalidate(inspectionStatsProvider);
        ref.invalidate(monthlyInspectionStatsProvider);
      }
    });

    return Scaffold(
      backgroundColor: Colors.white,
      extendBody: true,
      appBar: _selectedIndex == 0 ? const CarSpyTopAppBar() : null,
      body: Padding(
        padding: const EdgeInsets.only(bottom: 100),
        child: IndexedStack(
          index: _selectedIndex,
          children: [
            _buildHomeTab(),
            const ReportsPage(key: ValueKey('car_spy_reports')),
            const AttendanceScreen(key: ValueKey('car_spy_attendance')),
            const WorkAssignedScreen(key: ValueKey('car_spy_work_assigned')),
          ],
        ),
      ),
      bottomNavigationBar: CarSpyBottomNavBar(
        selectedIndex: _selectedIndex,
        onTap: (index) => setState(() => _selectedIndex = index),
      ),
    );
  }
}
