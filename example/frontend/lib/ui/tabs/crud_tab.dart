import 'package:example/database/supabase_select_builders.g.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tether_libs/client_manager/manager/client_manager_base.dart';
import 'package:tether_libs/utils/string_utils.dart';
import 'package:uuid/uuid.dart'; // For generating IDs

// Import your models, providers, and managers
import 'package:example/database/models.g.dart'; // Contains GenreModel
import 'package:example/database/managers/genres_client_manager.g.dart'; // Contains genresManagerProvider
import 'package:example/models/selects.dart'; // Contains genreSelect for fetching

// Provider for a list of genres to display
final genresListProvider =
    StreamProvider.autoDispose<TetherClientReturn<GenreModel>>((ref) {
      final genreManager = ref.watch(genresManagerProvider);
      // Fetch genres using the predefined 'genreSelect' for consistency
      return genreManager.query.select(genreSelect).asStream();
    });

class CrudTab extends ConsumerStatefulWidget {
  const CrudTab({super.key});

  @override
  ConsumerState<CrudTab> createState() => _CrudTabState();
}

class _CrudTabState extends ConsumerState<CrudTab> {
  final _formKey = GlobalKey<FormState>();
  // Controllers for a Genre form
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  String? _editingGenreId; // To keep track if we are editing an existing genre

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  void _clearForm() {
    _formKey.currentState?.reset();
    _nameController.clear();
    _descriptionController.clear();
    setState(() {
      _editingGenreId = null;
    });
  }

  Future<void> _submitForm() async {
    if (_formKey.currentState!.validate()) {
      final genreManager = ref.read(genresManagerProvider);
      final genreData = GenreModel(
        id: _editingGenreId ?? const Uuid().v4(), // Generate new ID if creating
        name: _nameController.text,
        description:
            _descriptionController.text.isNotEmpty
                ? _descriptionController.text
                : null,
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      );

      try {
        if (_editingGenreId == null) {
          // Create
          await genreManager.query.insert([genreData.toInput()]);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Genre created successfully!')),
            );
          }
        } else {
          // Update
          await genreManager.query
              .update(value: genreData.toInput())
              .eq(GenresColumn.id, genreData.id);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Genre updated successfully!')),
            );
          }
        }
        _clearForm();
        ref.invalidate(genresListProvider);
      } catch (e, s) {
        printLongString('Error submitting genre: $e $s');
      }
    }
  }

  void _editGenre(GenreModel genre) {
    setState(() {
      _editingGenreId = genre.id;
      _nameController.text = genre.name;
      _descriptionController.text = genre.description ?? '';
    });
  }

  Future<void> _deleteGenre(String genreId) async {
    try {
      final genreManager = ref.read(genresManagerProvider);
      // Assuming ClientManager's delete method takes the model or just the ID
      // For this example, let's assume it can find and delete by ID.
      // The actual delete might be: await genreManager.query.delete().eq('id', genreId).execute();
      // Or if you have a specific deleteById:
      final genreToDelete = GenreModel(
        id: genreId,
        name: '',
      ); // Minimal model for delete by ID
      await genreManager.query.delete(genreToDelete);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Genre deleted successfully!')),
        );
      }
      ref.invalidate(genresListProvider); // Refresh the list
      if (_editingGenreId == genreId) _clearForm();
    } catch (e) {
      print('Error deleting genre: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error deleting genre: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final genresAsyncValue = ref.watch(genresListProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _editingGenreId == null ? 'Create New Genre' : 'Edit Genre',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 16),
          Form(
            key: _formKey,
            child: Column(
              children: [
                TextFormField(
                  controller: _nameController,
                  decoration: const InputDecoration(labelText: 'Genre Name'),
                  validator:
                      (value) =>
                          value!.isEmpty ? 'Please enter a genre name' : null,
                ),
                TextFormField(
                  controller: _descriptionController,
                  decoration: const InputDecoration(
                    labelText: 'Description (Optional)',
                  ),
                  maxLines: 3,
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (_editingGenreId != null)
                      TextButton(
                        onPressed: _clearForm,
                        child: const Text('Cancel Edit'),
                      ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _submitForm,
                      child: Text(
                        _editingGenreId == null ? 'Create' : 'Update',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 30),
          Text(
            'Existing Genres',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 10),
          genresAsyncValue.when(
            data: (genres) {
              if (genres.data.isEmpty) {
                return const Center(
                  child: Text('No genres found. Create one!'),
                );
              }
              return ListView.builder(
                shrinkWrap: true,
                physics:
                    const NeverScrollableScrollPhysics(), // To use inside SingleChildScrollView
                itemCount: genres.data.length,
                itemBuilder: (context, index) {
                  final genre = genres.data[index];
                  return Card(
                    margin: const EdgeInsets.symmetric(vertical: 4.0),
                    child: ListTile(
                      title: Text(genre.name),
                      subtitle: Text(
                        genre.description ?? 'No description',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit, color: Colors.blue),
                            onPressed: () => _editGenre(genre),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete, color: Colors.red),
                            onPressed: () => _deleteGenre(genre.id),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error:
                (err, stack) =>
                    Center(child: Text('Error loading genres: $err')),
          ),
        ],
      ),
    );
  }
}
