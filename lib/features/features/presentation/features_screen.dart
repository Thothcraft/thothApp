import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/constants/app_constants.dart';
import '../../../shared/widgets/glass_card.dart';
import 'package:url_launcher/url_launcher.dart';

/// Features Screen - Comprehensive product features with tabbed content
/// Mirrors website Features.vue functionality
/// Replaces the old PlatformScreen
class FeaturesScreen extends StatefulWidget {
  const FeaturesScreen({super.key});

  @override
  State<FeaturesScreen> createState() => _FeaturesScreenState();
}

class _FeaturesScreenState extends State<FeaturesScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 6, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        children: [
          // Hero Section with Product Showcase
          Container(
            padding: const EdgeInsets.symmetric(vertical: 80, horizontal: 20),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  AppColors.backgroundLight,
                  AppColors.backgroundSecondaryLight,
                ],
              ),
            ),
            child: Column(
              children: [
                Text(
                  'Thoth IoT Device in Detail',
                  style: AppTextStyles.heroTitle.copyWith(
                    fontSize: 36,
                    color: AppColors.textPrimaryLight,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: Text(
                    'Explore the Raspberry Pi-powered IoT platform with Sense HAT sensors and PiSugar battery. Discover every component and capability.',
                    style: AppTextStyles.bodyLarge.copyWith(
                      color: AppColors.textSecondaryLight,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 32),
                // Product Image Carousel (replaces 3D model for mobile)
                SizedBox(
                  height: 300,
                  child: PageView(
                    children: [
                      _buildProductImage('assets/images/products/white_bg.jpg'),
                      _buildProductImage('assets/images/products/closeup.jpg'),
                      _buildProductImage(
                        'assets/images/products/lifestyle.jpg',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),
                Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  alignment: WrapAlignment.center,
                  children: [
                    ElevatedButton(
                      onPressed: () => _scrollToTab(0),
                      child: const Text('View Specs'),
                    ),
                    OutlinedButton(
                      onPressed: () => _scrollToTab(5),
                      child: const Text('See Demos'),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Tabbed Content Section
          Container(
            color: Colors.white,
            child: Column(
              children: [
                const SizedBox(height: 32),
                // Tab Bar
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 20),
                  decoration: BoxDecoration(
                    color: AppColors.backgroundSecondaryLight,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: TabBar(
                    controller: _tabController,
                    isScrollable: true,
                    indicator: BoxDecoration(
                      color: AppColors.primaryBlue,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    labelColor: Colors.white,
                    unselectedLabelColor: AppColors.textSecondaryLight,
                    labelStyle: AppTextStyles.labelMedium,
                    tabs: const [
                      Tab(text: 'Sensors'),
                      Tab(text: 'Interfaces'),
                      Tab(text: 'Researcher Kit'),
                      Tab(text: 'Education Kit'),
                      Tab(text: 'Use Cases'),
                      Tab(text: 'Plans'),
                    ],
                  ),
                ),
                const SizedBox(height: 32),
                // Tab Content
                SizedBox(
                  height: 600,
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _buildSensorsTab(),
                      _buildInterfacesTab(),
                      _buildResearcherTab(),
                      _buildEducationTab(),
                      _buildUseCasesTab(),
                      _buildPlansTab(),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Feature Comparison Table
          Container(
            color: AppColors.backgroundSecondaryLight,
            padding: const EdgeInsets.symmetric(vertical: 64, horizontal: 20),
            child: Column(
              children: [
                Text(
                  'Feature Comparison',
                  style: AppTextStyles.sectionTitle.copyWith(
                    color: AppColors.textPrimaryLight,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                _buildComparisonTable(),
              ],
            ),
          ),

          // Demo Videos Section
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 64, horizontal: 20),
            child: Column(
              children: [
                Text(
                  'See Thoth in Action',
                  style: AppTextStyles.sectionTitle.copyWith(
                    color: AppColors.textPrimaryLight,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Watch how students, researchers, and makers use Thoth to bring their ideas to life.',
                  style: AppTextStyles.bodyLarge.copyWith(
                    color: AppColors.textSecondaryLight,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 48),
                LayoutBuilder(
                  builder: (context, constraints) {
                    if (constraints.maxWidth > 600) {
                      return Row(
                        children: [
                          Expanded(
                            child: _buildDemoCard(
                              'Complete Overview',
                              'Full walkthrough of Thoth\'s capabilities and features.',
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: _buildDemoCard(
                              'Sensor Integration',
                              'Deep dive into our comprehensive sensor array.',
                            ),
                          ),
                        ],
                      );
                    }
                    return Column(
                      children: [
                        _buildDemoCard(
                          'Complete Overview',
                          'Full walkthrough of Thoth\'s capabilities and features.',
                        ),
                        const SizedBox(height: 16),
                        _buildDemoCard(
                          'Sensor Integration',
                          'Deep dive into our comprehensive sensor array.',
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProductImage(String path) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: AppColors.shadowLight,
            blurRadius: 20,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Image.asset(
          path,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            return Container(
              color: AppColors.backgroundSecondaryLight,
              child: const Icon(Icons.devices, size: 100),
            );
          },
        ),
      ),
    );
  }

  Widget _buildSensorsTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          GlassCard(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Text(
                    'Precision Data Collection',
                    style: AppTextStyles.h2
                        .copyWith(color: AppColors.textPrimaryLight),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Powered by Raspberry Pi Sense HAT: capture temperature, humidity, pressure, and motion data in real-time. Features WiFi captive portal for instant headless setup and PiSugar for portable power management.',
                    style: AppTextStyles.bodyMedium
                        .copyWith(color: AppColors.textSecondaryLight),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  _buildSensorGrid(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSensorGrid() {
    return GridView.count(
      crossAxisCount: 1,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 16,
      childAspectRatio: 3,
      children: [
        _buildSensorItem(
          Icons.thermostat,
          'Sense HAT Environmental',
          'Temperature, humidity, pressure via Sense HAT',
        ),
        _buildSensorItem(
          Icons.explore,
          'IMU Motion Tracking',
          '9-DOF IMU: accelerometer, gyroscope, compass',
        ),
        _buildSensorItem(
          Icons.battery_charging_full,
          'Power Management',
          'PiSugar battery with real-time monitoring',
        ),
      ],
    );
  }

  Widget _buildSensorItem(IconData icon, String title, String description) {
    return Row(
      children: [
        Icon(icon, size: 48, color: AppColors.primaryBlue),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                title,
                style: AppTextStyles.h4
                    .copyWith(color: AppColors.textPrimaryLight),
              ),
              const SizedBox(height: 4),
              Text(
                description,
                style: AppTextStyles.bodySmall
                    .copyWith(color: AppColors.textSecondaryLight),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildInterfacesTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: GlassCard(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Text(
                'Ubiquitous Access',
                style: AppTextStyles.h2
                    .copyWith(color: AppColors.textPrimaryLight),
              ),
              const SizedBox(height: 16),
              Text(
                'Multi-platform control (web/desktop/mobile/Chrome/voice/SMS) with Obsidian note-taking. Your data and ideas flow anywhere, organized as a personal knowledge hub.',
                style: AppTextStyles.bodyMedium
                    .copyWith(color: AppColors.textSecondaryLight),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              _buildInterfaceList(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInterfaceList() {
    final interfaces = [
      {'icon': Icons.web, 'title': 'Web Interface'},
      {'icon': Icons.desktop_windows, 'title': 'Desktop Application'},
      {'icon': Icons.smartphone, 'title': 'Mobile App'},
      {'icon': Icons.mic, 'title': 'Voice Control'},
      {'icon': Icons.sms, 'title': 'SMS Interface'},
      {'icon': Icons.note, 'title': 'Obsidian Integration'},
    ];

    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 16,
      crossAxisSpacing: 16,
      childAspectRatio: 2,
      children: interfaces.map((interface) {
        return Row(
          children: [
            Icon(interface['icon'] as IconData, color: AppColors.primaryBlue),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                interface['title'] as String,
                style: AppTextStyles.bodyMedium
                    .copyWith(color: AppColors.textPrimaryLight),
              ),
            ),
          ],
        );
      }).toList(),
    );
  }

  Widget _buildResearcherTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          GlassCard(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Text(
                    'Deep Learning & Collaboration',
                    style: AppTextStyles.h2
                        .copyWith(color: AppColors.textPrimaryLight),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Train models on-device or federated across Thoths. Multi-device sync with differential privacy protects sensitive data while enabling global teamwork.',
                    style: AppTextStyles.bodyMedium
                        .copyWith(color: AppColors.textSecondaryLight),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  _buildFeatureCard(
                    'Federated Learning',
                    'Collaborate across multiple devices while keeping data private',
                  ),
                  const SizedBox(height: 16),
                  _buildFeatureCard(
                    'Differential Privacy',
                    'Protect sensitive information during collaborative research',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEducationTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          GlassCard(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Text(
                    'Curriculum-Ready',
                    style: AppTextStyles.h2
                        .copyWith(color: AppColors.textPrimaryLight),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Pre-built lessons on AI/IoT, from basics to advanced. Pitch to students: \'Build, learn, share\'—with guided projects for immediate impact.',
                    style: AppTextStyles.bodyMedium
                        .copyWith(color: AppColors.textSecondaryLight),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  _buildEducationGrid(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEducationGrid() {
    return GridView.count(
      crossAxisCount: 1,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 24,
      childAspectRatio: 2,
      children: [
        _buildEducationItem(
          Icons.book,
          'Structured Curriculum',
          'Week-long projects from beginner to advanced',
        ),
        _buildEducationItem(
          Icons.extension,
          'Hands-on Projects',
          'Build real AI/IoT applications',
        ),
        _buildEducationItem(
          Icons.people,
          'Collaborative Learning',
          'Share and learn from peers',
        ),
      ],
    );
  }

  Widget _buildEducationItem(IconData icon, String title, String description) {
    return Column(
      children: [
        Icon(icon, size: 64, color: AppColors.primaryBlue),
        const SizedBox(height: 12),
        Text(
          title,
          style: AppTextStyles.h4.copyWith(color: AppColors.textPrimaryLight),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          description,
          style: AppTextStyles.bodySmall
              .copyWith(color: AppColors.textSecondaryLight),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildUseCasesTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Text(
            'Tailored Pitches',
            style: AppTextStyles.h2.copyWith(color: AppColors.textPrimaryLight),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          _buildUseCaseCard(
            Icons.school,
            'Students',
            'Boost productivity with AI-assisted notes and hands-on learning experiences',
            Colors.blue,
          ),
          const SizedBox(height: 16),
          _buildUseCaseCard(
            Icons.science,
            'Researchers',
            'Scale experiments ethically with federated learning and privacy protection',
            Colors.green,
          ),
          const SizedBox(height: 16),
          _buildUseCaseCard(
            Icons.build,
            'Makers',
            'Hack and collaborate endlessly with open-source extensibility',
            Colors.orange,
          ),
        ],
      ),
    );
  }

  Widget _buildUseCaseCard(
    IconData icon,
    String title,
    String description,
    Color color,
  ) {
    return GlassCard(
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              color.withValues(alpha: 0.1),
              Colors.white,
            ],
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 48, color: color),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppTextStyles.h4
                        .copyWith(color: AppColors.textPrimaryLight),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    description,
                    style: AppTextStyles.bodySmall
                        .copyWith(color: AppColors.textSecondaryLight),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlansTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Text(
            'Flexible Tiers',
            style: AppTextStyles.h2.copyWith(color: AppColors.textPrimaryLight),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          _buildPlanCard(
            'Free',
            '\$0/mo',
            'For entry-level exploration and learning',
            false,
          ),
          const SizedBox(height: 16),
          _buildPlanCard(
            'Paid',
            '\$9.99/mo',
            'For power users and dedicated researchers',
            true,
          ),
          const SizedBox(height: 16),
          _buildPlanCard(
            'Organization',
            'Custom',
            'For teams with institutional discounts',
            false,
          ),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => _launchUrl(AppConstants.portalUrl),
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('View Full Comparison'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlanCard(
    String title,
    String price,
    String description,
    bool featured,
  ) {
    return GlassCard(
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: featured
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AppColors.primaryBlue, width: 2),
              )
            : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  title,
                  style: AppTextStyles.h3.copyWith(
                    color: featured
                        ? AppColors.primaryBlue
                        : AppColors.textPrimaryLight,
                  ),
                ),
                if (featured)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.primaryBlue,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'Popular',
                      style: AppTextStyles.labelSmall
                          .copyWith(color: Colors.white),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              price,
              style:
                  AppTextStyles.h2.copyWith(color: AppColors.textPrimaryLight),
            ),
            const SizedBox(height: 8),
            Text(
              description,
              style: AppTextStyles.bodySmall
                  .copyWith(color: AppColors.textSecondaryLight),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFeatureCard(String title, String description) {
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style:
                  AppTextStyles.h4.copyWith(color: AppColors.textPrimaryLight),
            ),
            const SizedBox(height: 8),
            Text(
              description,
              style: AppTextStyles.bodySmall
                  .copyWith(color: AppColors.textSecondaryLight),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildComparisonTable() {
    return GlassCard(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowColor:
              WidgetStateProperty.all(AppColors.backgroundSecondaryLight),
          columns: const [
            DataColumn(
              label: Text(
                'Feature',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            DataColumn(
              label: Text(
                'Thoth',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            DataColumn(
              label: Text(
                'Traditional Tools',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
          rows: const [
            DataRow(
              cells: [
                DataCell(Text('Multi-Platform Access')),
                DataCell(Text('✓ Web, Mobile, Desktop, Voice, SMS')),
                DataCell(Text('Limited platforms')),
              ],
            ),
            DataRow(
              cells: [
                DataCell(Text('Sensor Integration')),
                DataCell(Text('✓ Built-in comprehensive kit')),
                DataCell(Text('Separate purchases required')),
              ],
            ),
            DataRow(
              cells: [
                DataCell(Text('Note-taking Integration')),
                DataCell(Text('✓ Obsidian sync')),
                DataCell(Text('Manual organization')),
              ],
            ),
            DataRow(
              cells: [
                DataCell(Text('Collaboration')),
                DataCell(Text('✓ Federated + Privacy')),
                DataCell(Text('N/A in most tools')),
              ],
            ),
            DataRow(
              cells: [
                DataCell(Text('Education Ready')),
                DataCell(Text('✓ Pre-built curriculum')),
                DataCell(Text('DIY setup required')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDemoCard(String title, String description) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 200,
            decoration: const BoxDecoration(
              color: AppColors.backgroundSecondaryLight,
              borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
            ),
            child: const Center(
              child:
                  Icon(Icons.sensors, size: 64, color: AppColors.primaryBlue),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppTextStyles.h4
                      .copyWith(color: AppColors.textPrimaryLight),
                ),
                const SizedBox(height: 8),
                Text(
                  description,
                  style: AppTextStyles.bodySmall
                      .copyWith(color: AppColors.textSecondaryLight),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _scrollToTab(int index) {
    _tabController.animateTo(index);
  }

  Future<void> _launchUrl(String urlString) async {
    final uri = Uri.parse(urlString);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
