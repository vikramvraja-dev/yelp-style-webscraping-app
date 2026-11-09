import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../restaurant_provider.dart';
import '../restaurant.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:image_picker/image_picker.dart';

class ListTab extends StatelessWidget {
  const ListTab({super.key});

  Future<void> _takeFoodPhoto(BuildContext context, String restaurantId) async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.camera);

    if (image != null && context.mounted) {
      context.read<RestaurantProvider>().addJournalImage(restaurantId, image.path);
    }
  }

  void _showJournalEntry(BuildContext context, Restaurant res) {
    // Controller to hold the existing notes if they already wrote some
    final TextEditingController notesController = TextEditingController(text: res.notes ?? '');

    showModalBottomSheet(
      context: context,
      isScrollControlled: true, // Allows sheet to push up when keyboard opens
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom, // Avoid keyboard
            left: 24.0, right: 24.0, top: 24.0,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(child: Text("Journal: ${res.name}", style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold))),
                  // Moved the web link button inside the journal entry
                  IconButton(
                    icon: const Icon(Icons.open_in_browser, color: Colors.blue),
                    onPressed: () async {
                      if (res.url.isNotEmpty) {
                        final Uri url = Uri.parse(res.url);
                        if (await canLaunchUrl(url)) await launchUrl(url, mode: LaunchMode.inAppBrowserView);
                      }
                    },
                  )
                ],
              ),
              const SizedBox(height: 16),

              // Display the user's camera photo if they took one!
              if (res.localImagePath != null && res.localImagePath!.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.file(File(res.localImagePath!), width: double.infinity, height: 200, fit: BoxFit.cover),
                )
              else
                Container(
                  width: double.infinity, height: 100,
                  decoration: BoxDecoration(color: Colors.grey[200], borderRadius: BorderRadius.circular(12)),
                  child: const Center(child: Text("No food photo yet! Tap the camera icon.", style: TextStyle(color: Colors.grey))),
                ),

              const SizedBox(height: 16),

              // The Notes Text Box
              TextField(
                controller: notesController,
                maxLines: 4,
                decoration: InputDecoration(
                  hintText: "What did you eat? How was the experience?",
                  filled: true,
                  fillColor: Colors.grey[50],
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 16),

              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    padding: const EdgeInsets.symmetric(vertical: 14)
                  ),
                  onPressed: () {
                    // Save the text to sqflite via the provider
                    context.read<RestaurantProvider>().updateJournalNotes(res.id, notesController.text);
                    Navigator.pop(context);
                  },
                  child: const Text("Save Journal Entry", style: TextStyle(color: Colors.white, fontSize: 16)),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        );
      }
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<RestaurantProvider>();
    final list = provider.mustTryList;

    return Scaffold(
      appBar: AppBar(title: const Text("MUST TRY LIST")),
      body: list.isEmpty
        ? const Center(child: Text("Swipe right on cards to add to your list!"))
        : ListView.builder(
            physics: const BouncingScrollPhysics(),
            itemCount: list.length,
            itemBuilder: (context, index) {
              final res = list[index];
              final hasLocalImage = res.localImagePath != null && res.localImagePath!.isNotEmpty;

              return ListTile(
                leading: hasLocalImage
                    ? ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.file(File(res.localImagePath!), width: 50, height: 50, fit: BoxFit.cover))
                    : res.imageUrl.isEmpty
                      ? const SizedBox(width: 50, height: 50, child: Icon(Icons.image_not_supported, color: Colors.grey))
                      : ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.network(
                            res.imageUrl, width: 50, height: 50, fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) => const SizedBox(width: 50, height: 50, child: Icon(Icons.image_not_supported, color: Colors.grey)),
                          ),
                        ),
                onTap: () => _showJournalEntry(context, res),
                title: Text(res.name),
                subtitle: Text("Added: ${res.dateAdded}"),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.camera_alt, color: Colors.blue),
                      onPressed: () => _takeFoodPhoto(context, res.id),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete, color: Colors.red),
                      onPressed: () => context.read<RestaurantProvider>().removeRestaurant(res.id),
                    ),
                  ],
                ),
              );
            },
          ),
    );
  }
}