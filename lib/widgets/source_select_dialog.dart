import 'package:flutter/material.dart';
import '../config/theme.dart';

class SourceSelectDialog extends StatelessWidget {
  final List<String> sourceNames;
  final String? selectedSource;

  const SourceSelectDialog({
    super.key,
    required this.sourceNames,
    this.selectedSource,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '选择书源',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 16),
            ...sourceNames.map((source) => _buildSourceItem(context, source)),
          ],
        ),
      ),
    );
  }

  Widget _buildSourceItem(BuildContext context, String name) {
    final isSelected = name == selectedSource;
    return ListTile(
      leading: Icon(
        isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
        color: isSelected ? AppTheme.primaryColor : AppTheme.textHint,
        size: 20,
      ),
      title: Text(
        name,
        style: TextStyle(
          fontSize: 15,
          color: isSelected ? AppTheme.primaryColor : AppTheme.textPrimary,
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      onTap: () => Navigator.of(context).pop(name),
    );
  }
}
