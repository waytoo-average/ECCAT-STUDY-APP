// Imports specific to To-Do features
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert'; // For jsonDecode and jsonEncode
import 'package:flutter/services.dart'; // For HapticFeedback
import 'package:intl/intl.dart'; // For date formatting
import 'dart:developer' as developer; // For logging
import 'package:flutter_local_notifications/flutter_local_notifications.dart'; // For notifications
import 'package:timezone/timezone.dart' as tz; // For timezone in notifications

// Core app imports (from app_core.dart)
import 'package:app/app_core.dart';

import 'l10n/app_localizations.dart';
import 'main.dart'; // For AppLocalizations, showAppSnackBar


// TodoItem class for persistence and enhanced fields
class TodoItem {
  String title;
  bool isCompleted;
  DateTime? dueDate;
  TimeOfDay? dueTime;
  bool isRepeating;
  String? repeatInterval;
  String? listName;
  DateTime creationDate;

  TodoItem({
    required this.title,
    this.isCompleted = false,
    this.dueDate,
    this.dueTime,
    this.isRepeating = false,
    this.repeatInterval,
    this.listName,
    DateTime? creationDate,
  }) : creationDate = creationDate ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'title': title,
    'isCompleted': isCompleted,
    'dueDate': dueDate?.toIso8601String(),
    'dueTimeHour': dueTime?.hour,
    'dueTimeMinute': dueTime?.minute,
    'isRepeating': isRepeating,
    'repeatInterval': repeatInterval,
    'listName': listName,
    'creationDate': creationDate.toIso8601String(),
  };

  factory TodoItem.fromJson(Map<String, dynamic> json) {
    return TodoItem(
      title: json['title'] as String,
      isCompleted: json['isCompleted'] as bool,
      dueDate: json['dueDate'] != null ? DateTime.parse(json['dueDate'] as String) : null,
      dueTime: (json['dueTimeHour'] != null && json['dueTimeMinute'] != null)
          ? TimeOfDay(hour: json['dueTimeHour'] as int, minute: json['dueTimeMinute'] as int)
          : null,
      isRepeating: json['isRepeating'] as bool? ?? false,
      repeatInterval: json['repeatInterval'] as String?,
      listName: json['listName'] as String?,
      creationDate: json['creationDate'] != null ? DateTime.parse(json['creationDate'] as String) : DateTime(2000, 1, 1),
    );
  }

  bool get isOverdue {
    if (dueDate == null || isCompleted) return false;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final taskDate = DateTime(dueDate!.year, dueDate!.month, dueDate!.day);

    if (taskDate.isBefore(today)) {
      return true;
    }
    if (taskDate.isAtSameMomentAs(today) && dueTime != null) {
      final taskDateTime = DateTime(now.year, now.month, now.day, dueTime!.hour, dueTime!.minute);
      return taskDateTime.isBefore(now);
    }
    return false;
  }

  bool get isToday {
    if (dueDate == null || isCompleted) return false;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final taskDate = DateTime(dueDate!.year, dueDate!.month, dueDate!.day);
    return taskDate.isAtSameMomentAs(today);
  }

  bool get isTomorrow {
    if (dueDate == null || isCompleted) return false;
    final now = DateTime.now();
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    final taskDate = DateTime(dueDate!.year, dueDate!.month, dueDate!.day);
    return taskDate.isAtSameMomentAs(tomorrow);
  }

  bool get isThisWeek {
    if (dueDate == null || isCompleted) return false;
    if (isToday || isTomorrow) return false;
    final now = DateTime.now();
    final startOfWeek = now.subtract(Duration(days: now.weekday - 1));
    final endOfWeek = startOfWeek.add(const Duration(days: 6));

    final taskDate = DateTime(dueDate!.year, dueDate!.month, dueDate!.day);
    return taskDate.isAfter(startOfWeek.subtract(const Duration(milliseconds: 1))) && taskDate.isBefore(endOfWeek.add(const Duration(days: 1)));
  }

  String formatDueDate(BuildContext context, AppLocalizations s) {
    if (dueDate == null) return s.notSet;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    final taskDate = DateTime(dueDate!.year, dueDate!.month, dueDate!.day);

    String dateText;
    if (taskDate.isAtSameMomentAs(today)) {
      dateText = s.todayTasks;
    } else if (taskDate.isAtSameMomentAs(tomorrow)) {
      dateText = s.tomorrowTasks;
    } else if (isThisWeek) {
      dateText = DateFormat.EEEE(Localizations.localeOf(context).toLanguageTag()).format(dueDate!);
    } else {
      dateText = DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag()).format(dueDate!);
    }

    String timeText = '';
    if (dueTime != null) {
      final materialLocalizations = MaterialLocalizations.of(context);
      timeText = materialLocalizations.formatTimeOfDay(dueTime!, alwaysUse24HourFormat: MediaQuery.of(context).alwaysUse24HourFormat);
    }

    if (timeText.isNotEmpty) {
      return '$dateText, $timeText';
    }
    return dateText;
  }
}

// TodoListScreen
class TodoListScreen extends StatefulWidget {
  const TodoListScreen({super.key});

  @override
  State<TodoListScreen> createState() => _TodoListScreenState();
}

class _TodoListScreenState extends State<TodoListScreen> {
  final TextEditingController _taskController = TextEditingController();
  List<TodoItem> _todos = []; // This will now be a filtered/sorted view of data from Provider
  bool _isLoading = true;
  bool _isSearching = false;

  String _currentList = 'INITIAL_PLACEHOLDER';
  String _searchQuery = '';

  // Removed GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();

  @override
  void initState() {
    super.initState();
    // Listen to changes from TodoSummaryProvider
    Provider.of<TodoSummaryProvider>(context, listen: false).addListener(_onTodosChanged);
    _loadTodos();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = AppLocalizations.of(context);

    if (s != null) {
      if (_currentList == 'INITIAL_PLACEHOLDER' || !_isLocalizedList(_currentList, s)) {
        _currentList = s.allListsTitle;
      }
      _applyFilters();
    }
  }

  @override
  void dispose() {
    // Ensure the listener is removed to prevent memory leaks and "deactivated widget" errors
    Provider.of<TodoSummaryProvider>(context, listen: false).removeListener(_onTodosChanged);
    _taskController.dispose();
    super.dispose();
  }

  void _onTodosChanged() {
    if (!mounted) return; // Crucial check for preventing "deactivated widget" errors
    _loadTodos(); // Reloads the filtered list based on the updated provider data
  }

  Future<void> _loadTodos() async {
    if (!mounted) return; // Crucial check for preventing "deactivated widget" errors
    // Get the raw list of todos from the provider
    final todoProvider = Provider.of<TodoSummaryProvider>(context, listen: false);

    // Sort and filter the provider's allTodos list
    List<TodoItem> fetchedTodos = todoProvider.allTodos;

    if (mounted) { // Ensure mounted before setState
      setState(() {
        _todos = fetchedTodos; // Update internal list with provider's data
        _isLoading = false;
        _applyFilters();
      });
    }
  }

  bool _isLocalizedList(String listName, AppLocalizations s) {
    return listName == s.allListsTitle ||
        listName == s.personal ||
        listName == s.work ||
        listName == s.shopping ||
        listName == s.defaultList;
  }

  void _addTodo(AppLocalizations s) async {
    if (!mounted) return; // Ensure mounted
    final String newTaskTitle = _taskController.text.trim();
    if (newTaskTitle.isNotEmpty) {
      final newItem = TodoItem(
        title: newTaskTitle,
        listName: _currentList == s.allListsTitle ? null : (_currentList == s.defaultList ? null : _currentList), // Corrected defaultList handling
      );

      await Provider.of<TodoSummaryProvider>(context, listen: false).saveTodo(newItem); // Save via provider

      _taskController.clear();
      HapticFeedback.lightImpact();
      if (mounted) { // Ensure mounted
        showAppSnackBar(context, s.taskAdded, icon: Icons.task_alt, iconColor: Colors.green);
      }

      await _scheduleNotification(newItem, s); // Schedule notification
    } else {
      showAppSnackBar(context, s.emptyTaskError, icon: Icons.warning_amber_outlined, iconColor: Colors.orange);
    }
  }

  void _toggleTodoCompletion(int index) async {
    if (!mounted) return; // Ensure mounted
    final s = AppLocalizations.of(context)!;
    final TodoItem itemToToggle = _getFilteredTodos()[index];

    // Create a copy to modify its completion status
    final updatedItem = TodoItem(
      title: itemToToggle.title,
      isCompleted: !itemToToggle.isCompleted, // Toggle status
      dueDate: itemToToggle.dueDate,
      dueTime: itemToToggle.dueTime,
      isRepeating: itemToToggle.isRepeating,
      repeatInterval: itemToToggle.repeatInterval,
      listName: itemToToggle.listName,
      creationDate: itemToToggle.creationDate,
    );

    await Provider.of<TodoSummaryProvider>(context, listen: false).saveTodo(updatedItem); // Save via provider

    HapticFeedback.lightImpact();
    if (mounted) { // Ensure mounted
      if (updatedItem.isCompleted) {
        showAppSnackBar(context, s.taskCompleted, icon: Icons.check_circle_outline, iconColor: Colors.green);
        flutterLocalNotificationsPlugin.cancel(itemToToggle.hashCode);
      } else {
        showAppSnackBar(context, s.taskReactivated, icon: Icons.refresh, iconColor: Colors.blue);
        await _scheduleNotification(updatedItem, s); // Re-schedule if reactivated
      }
    }
  }

  void _deleteTodo(int index) async {
    if (!mounted) return; // Ensure mounted
    final s = AppLocalizations.of(context)!;
    final TodoItem itemToDelete = _getFilteredTodos()[index];

    // Removed AnimatedList removeItem for simpler ListView.builder handling
    // _listKey.currentState?.removeItem(...);

    await Provider.of<TodoSummaryProvider>(context, listen: false).deleteTodo(itemToDelete); // Delete via provider

    HapticFeedback.lightImpact();
    if (mounted) { // Ensure mounted
      showAppSnackBar(context, s.taskDeleted, icon: Icons.delete_outline, iconColor: Colors.red);
      flutterLocalNotificationsPlugin.cancel(itemToDelete.hashCode);
    }
  }


  List<TodoItem> _getFilteredTodos() {
    final s = AppLocalizations.of(context)!;
    List<TodoItem> filteredTodos = _todos.where((todo) { // Filter _todos (which comes from Provider.allTodos)
      if (_currentList != s.allListsTitle) {
        if (todo.listName == null && _currentList == s.defaultList) {
          return true;
        } else if (todo.listName != _currentList) {
          return false;
        }
      }

      if (_searchQuery.isNotEmpty && !todo.title.toLowerCase().contains(_searchQuery.toLowerCase())) {
        return false;
      }
      return true;
    }).toList();

    filteredTodos.sort((a, b) {
      if (a.isCompleted != b.isCompleted) return a.isCompleted ? 1 : -1;

      if (a.dueDate == null && b.dueDate == null) {
        return a.creationDate.compareTo(b.creationDate);
      }
      if (a.dueDate == null) return 1;
      if (b.dueDate == null) return -1;
      int dueDateComparison = a.dueDate!.compareTo(b.dueDate!);
      if (dueDateComparison != 0) return dueDateComparison;

      return a.creationDate.compareTo(b.creationDate);
    });

    return filteredTodos;
  }

  void _applyFilters() {
    if(mounted) { // Ensure mounted
      setState(() { });
    }
  }

  Future<void> _scheduleNotification(TodoItem task, AppLocalizations s) async {
    if (!mounted) return; // Ensure mounted
    // Access the global flutterLocalNotificationsPlugin from main.dart via Provider
    final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    Provider.of<FlutterLocalNotificationsPlugin>(context, listen: false);


    if (task.dueDate == null || task.dueTime == null || task.isCompleted) {
      flutterLocalNotificationsPlugin.cancel(task.hashCode);
      return;
    }

    final now = DateTime.now();
    DateTime scheduleDateTime = DateTime(
      task.dueDate!.year,
      task.dueDate!.month,
      task.dueDate!.day,
      task.dueTime!.hour,
      task.dueTime!.minute,
    );

    if (scheduleDateTime.isBefore(now)) {
      developer.log("Notification not scheduled: Task time is in the past for '${task.title}'.", name: "Notifications");
      return;
    }

    final tz.TZDateTime tzScheduleDateTime = tz.TZDateTime.from(
      scheduleDateTime,
      tz.local,
    );


    const AndroidNotificationDetails androidNotificationDetails =
    AndroidNotificationDetails(
      'task_reminders_channel',
      'Task Reminders',
      channelDescription: 'Reminders for your ECCAT Study Station tasks',
      importance: Importance.max,
      priority: Priority.high,
      ticker: 'ticker',
    );
    const DarwinNotificationDetails darwinNotificationDetails = DarwinNotificationDetails();
    final NotificationDetails notificationDetails = NotificationDetails(
      android: androidNotificationDetails,
      iOS: darwinNotificationDetails,
    );

    DateTimeComponents? dateTimeComponents;
    if (task.isRepeating) {
      if (task.repeatInterval == s.daily) {
        dateTimeComponents = DateTimeComponents.time;
      } else if (task.repeatInterval == s.weekly) {
        dateTimeComponents = DateTimeComponents.dayOfWeekAndTime;
      } else if (task.repeatInterval == s.monthly) {
        dateTimeComponents = DateTimeComponents.dayOfMonthAndTime;
      } else if (task.repeatInterval == s.everyXDays(2)) { // This one won't repeat with DateTimeComponents
        dateTimeComponents = null;
      } else if (task.repeatInterval == s.weekdays) {
        dateTimeComponents = DateTimeComponents.dayOfWeekAndTime;
      } else if (task.repeatInterval == s.weekends) {
        dateTimeComponents = DateTimeComponents.dayOfWeekAndTime;
      }
    }

    await flutterLocalNotificationsPlugin.zonedSchedule(
      task.hashCode,
      s.appTitle,
      '${s.notificationReminderBody} ${task.title}',
      tzScheduleDateTime,
      notificationDetails,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      matchDateTimeComponents: dateTimeComponents,
      payload: 'task_id:${task.hashCode}',
    );

    developer.log("Notification scheduled for task '${task.title}' at $scheduleDateTime. Repeat: ${task.repeatInterval}", name: "Notifications");
  }


  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context)!;
    final List<TodoItem> displayedTodos = _getFilteredTodos();

    final List<String> availableLists = [
      s.allListsTitle,
      s.personal,
      s.work,
      s.shopping,
      s.defaultList,
    ];

    final DateTime today = DateTime.now();
    // Use provider's allTodos for calculating these stats
    final List<TodoItem> todayTasks = Provider.of<TodoSummaryProvider>(context).allTodos.where((todo) =>
    todo.dueDate != null &&
        todo.dueDate!.year == today.year &&
        todo.dueDate!.month == today.month &&
        todo.dueDate!.day == today.day
    ).toList();
    final int totalTodayTasks = todayTasks.length;
    final int completedTodayTasks = todayTasks.where((todo) => todo.isCompleted).length;
    final double todayProgress = totalTodayTasks > 0 ? completedTodayTasks / totalTodayTasks : 0.0;


    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.background,
      body: Column(
        children: [
          AppBar(
            title: _isSearching
                ? TextField(
              decoration: InputDecoration(
                hintText: s.searchTasksHint,
                hintStyle: TextStyle(color: Theme.of(context).colorScheme.onPrimary.withOpacity(0.7)),
                border: InputBorder.none,
                suffixIcon: IconButton(
                  icon: Icon(Icons.clear, color: Theme.of(context).colorScheme.onPrimary),
                  onPressed: () {
                    setState(() {
                      _searchQuery = '';
                      _isSearching = false;
                      _taskController.clear();
                      _applyFilters();
                    });
                  },
                ),
              ),
              style: TextStyle(color: Theme.of(context).colorScheme.onPrimary, fontSize: 17),
              autofocus: true,
              onChanged: (query) {
                setState(() {
                  _searchQuery = query;
                  _applyFilters();
                });
              },
            )
                : DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _currentList,
                dropdownColor: Theme.of(context).appBarTheme.backgroundColor,
                style: Theme.of(context).appBarTheme.titleTextStyle?.copyWith(
                  color: Theme.of(context).colorScheme.onPrimary,
                ),
                icon: Icon(Icons.arrow_drop_down, color: Theme.of(context).colorScheme.onPrimary),
                onChanged: (String? newValue) {
                  if (newValue != null) {
                    setState(() {
                      _currentList = newValue;
                      _applyFilters();
                    });
                  }
                },
                items: availableLists.map<DropdownMenuItem<String>>((String value) {
                  return DropdownMenuItem<String>(
                    value: value,
                    child: Text(value),
                  );
                }).toList(),
              ),
            ),
            automaticallyImplyLeading: false,
            actions: [
              IconButton(
                icon: _isSearching ? const Icon(Icons.search_off) : const Icon(Icons.search),
                onPressed: () {
                  setState(() {
                    _isSearching = !_isSearching;
                    _searchQuery = '';
                    if (!_isSearching) {
                      _applyFilters();
                    }
                  });
                },
                tooltip: s.searchTooltip,
              ),
            ],
          ),
          if (totalTodayTasks > 0 && _currentList == s.allListsTitle && !_isSearching)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.todayTasksProgress(completedTodayTasks, totalTodayTasks),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onBackground,
                    ),
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: todayProgress,
                    backgroundColor: Theme.of(context).colorScheme.onBackground.withOpacity(0.2),
                    valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).colorScheme.secondary),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ],
              ),
            ),
          Expanded(
            // Replaced AnimatedList with ListView.builder for robustness
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : displayedTodos.isEmpty
                ? _buildEmptyState(Icons.task_alt_outlined, _searchQuery.isNotEmpty ? s.noMatchingTasks : s.noTasksIllustrationText)
                : ListView.builder(
              padding: const EdgeInsets.all(8.0),
              itemCount: displayedTodos.length,
              itemBuilder: (context, index) {
                final todo = displayedTodos[index];
                return _buildTodoCard(context, todo, index, s);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _taskController,
                    decoration: InputDecoration(
                      hintText: s.enterQuickTaskHint,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
                    style: Theme.of(context).textTheme.bodyMedium,
                    onSubmitted: (_) => _addTodo(s),
                  ),
                ),
                const SizedBox(width: 10),
                ElevatedButton(
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    _addTodo(s);
                  },
                  style: ElevatedButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    minimumSize: const Size(60, 60),
                    padding: EdgeInsets.zero,
                    backgroundColor: Theme.of(context).colorScheme.secondary,
                    foregroundColor: Theme.of(context).colorScheme.onSecondary,
                  ),
                  child: const Icon(Icons.add, size: 30),
                ),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          HapticFeedback.lightImpact();
          // No need to await result for saving, as TodoDetailScreen saves directly
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) {
                return const TodoDetailScreen();
              },
            ),
          );
          // On returning, the TodoListScreen's listener to TodoSummaryProvider will
          // trigger a refresh, so no explicit refresh needed here.
        },
        child: const Icon(Icons.add),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }

  Widget _buildEmptyState(IconData icon, String message) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(icon, size: 80, color: Theme.of(context).colorScheme.onBackground.withOpacity(0.4)),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20.0),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(context).colorScheme.onBackground.withOpacity(0.7),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTodoCard(BuildContext context, TodoItem todo, int index, AppLocalizations s) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 0.0),
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        leading: Checkbox(
          value: todo.isCompleted,
          onChanged: (bool? value) {
            HapticFeedback.lightImpact();
            _toggleTodoCompletion(index);
          },
          fillColor: MaterialStateProperty.resolveWith((states) {
            if (states.contains(MaterialState.selected)) {
              return Theme.of(context).colorScheme.secondary;
            }
            return null;
          }),
        ),
        title: Text(
          todo.title,
          style: TextStyle(
            fontSize: 16,
            decoration: todo.isCompleted ? TextDecoration.lineThrough : null,
            color: todo.isCompleted ? Theme.of(context).textTheme.bodySmall?.color : Theme.of(context).textTheme.bodyLarge?.color,
          ),
        ),
        subtitle: (todo.dueDate != null || todo.dueTime != null) && !todo.isCompleted
            ? Text(
          todo.formatDueDate(context, s),
          style: TextStyle(
            fontSize: 12,
            color: todo.isOverdue ? Colors.red : Theme.of(context).textTheme.bodySmall?.color,
          ),
        )
            : null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (todo.isRepeating && !todo.isCompleted)
              Icon(Icons.repeat, size: 18, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6)),
            if (todo.isRepeating && !todo.isCompleted) const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              color: Colors.red[400],
              onPressed: () {
                HapticFeedback.lightImpact();
                _deleteTodo(index);
              },
            ),
          ],
        ),
        onTap: () async {
          HapticFeedback.lightImpact();
          // Pass the original TodoItem for editing
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) {
                return TodoDetailScreen(
                  todoItem: todo, // Pass the actual todo object
                );
              },
            ),
          );
          // Saving is now handled by TodoDetailScreen itself.
          // Re-schedule notification based on potential edits after returning.
          await _scheduleNotification(todo, s);
        },
      ),
    );
  }
}

class TodoDetailScreen extends StatefulWidget {
  final TodoItem? todoItem;

  const TodoDetailScreen({super.key, this.todoItem});

  @override
  State<TodoDetailScreen> createState() => _TodoDetailScreenState();
}

class _TodoDetailScreenState extends State<TodoDetailScreen> {
  final TextEditingController _titleController = TextEditingController();
  DateTime? _selectedDate;
  TimeOfDay? _selectedTime;
  String? _selectedRepeatInterval;
  String? _selectedListName;
  bool _isEditing = false;
  late DateTime _creationDate; // Use creationDate as a stable ID for edits
  bool _notificationsEnabled = true;

  @override
  void initState() {
    super.initState();
    if (widget.todoItem != null) {
      _isEditing = true;
      _titleController.text = widget.todoItem!.title;
      _selectedDate = widget.todoItem!.dueDate;
      _selectedTime = widget.todoItem!.dueTime;
      _selectedRepeatInterval = widget.todoItem!.repeatInterval;
      _selectedListName = widget.todoItem!.listName;
      _creationDate = widget.todoItem!.creationDate;
      _notificationsEnabled = (widget.todoItem!.dueDate != null && widget.todoItem!.dueTime != null);
    } else {
      _creationDate = DateTime.now(); // For new tasks, set creation date now
      _notificationsEnabled = false;
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _pickDate(AppLocalizations s) async {
    HapticFeedback.lightImpact();
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate ?? DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(days: 365 * 5)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 10)),
      locale: Localizations.localeOf(context),
    );
    if (picked != null && picked != _selectedDate) {
      if (!mounted) return; // Mounted check
      setState(() {
        _selectedDate = picked;
        if (_selectedTime == null) {
          _selectedTime = TimeOfDay.now();
        }
        _notificationsEnabled = true;
      });
    }
  }

  Future<void> _pickTime(AppLocalizations s) async {
    HapticFeedback.lightImpact();
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: _selectedTime ?? TimeOfDay.now(),
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: false),
          child: child!,
        );
      },
    );
    if (picked != null && picked != _selectedTime) {
      if (!mounted) return; // Mounted check
      setState(() {
        _selectedTime = picked;
        if (_selectedDate == null) {
          _selectedDate = DateTime.now();
        }
        _notificationsEnabled = true;
      });
    }
  }

  void _saveTask(AppLocalizations s) async { // Made async
    if (!mounted) return; // Mounted check
    final String title = _titleController.text.trim();
    if (title.isEmpty) {
      showAppSnackBar(context, s.emptyTaskError, icon: Icons.warning_amber_outlined, iconColor: Colors.orange);
      return;
    }
    HapticFeedback.lightImpact();

    DateTime? finalDueDate = _selectedDate;
    TimeOfDay? finalDueTime = _selectedTime;
    String? finalRepeatInterval = _selectedRepeatInterval;

    if (!_notificationsEnabled) {
      finalDueDate = null;
      finalDueTime = null;
      finalRepeatInterval = null;
    }

    final TodoItem todoToSave = TodoItem(
      title: title,
      isCompleted: widget.todoItem?.isCompleted ?? false,
      dueDate: finalDueDate,
      dueTime: finalDueTime,
      isRepeating: finalRepeatInterval != null && finalRepeatInterval != s.noRepeat,
      repeatInterval: finalRepeatInterval == s.noRepeat ? null : finalRepeatInterval,
      listName: _selectedListName == s.defaultList ? null : _selectedListName,
      creationDate: _creationDate, // Use the original creation date for existing tasks
    );

    // Use the TodoSummaryProvider to save the task
    await Provider.of<TodoSummaryProvider>(context, listen: false).saveTodo(todoToSave);

    // Schedule notification (if any) after saving
    await _scheduleNotification(todoToSave, s);

    if (mounted) { // Mounted check before showing snackbar and popping
      showAppSnackBar(context, s.taskSaved, icon: Icons.check, iconColor: Colors.green);
      Navigator.pop(context); // Pop without returning, as saving is handled here
    }
  }

  Future<void> _scheduleNotification(TodoItem task, AppLocalizations s) async {
    if (!mounted) return; // Mounted check
    final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    Provider.of<FlutterLocalNotificationsPlugin>(context, listen: false);

    if (task.dueDate == null || task.dueTime == null || task.isCompleted) {
      flutterLocalNotificationsPlugin.cancel(task.hashCode);
      return;
    }

    final now = DateTime.now();
    DateTime scheduleDateTime = DateTime(
      task.dueDate!.year,
      task.dueDate!.month,
      task.dueDate!.day,
      task.dueTime!.hour,
      task.dueTime!.minute,
    );

    if (scheduleDateTime.isBefore(now)) {
      developer.log("Notification not scheduled: Task time is in the past for '${task.title}'.", name: "Notifications");
      return;
    }

    final tz.TZDateTime tzScheduleDateTime = tz.TZDateTime.from(
      scheduleDateTime,
      tz.local,
    );


    const AndroidNotificationDetails androidNotificationDetails =
    AndroidNotificationDetails(
      'task_reminders_channel',
      'Task Reminders',
      channelDescription: 'Reminders for your ECCAT Study Station tasks',
      importance: Importance.max,
      priority: Priority.high,
      ticker: 'ticker',
    );
    const DarwinNotificationDetails darwinNotificationDetails = DarwinNotificationDetails();
    final NotificationDetails notificationDetails = NotificationDetails(
      android: androidNotificationDetails,
      iOS: darwinNotificationDetails,
    );

    DateTimeComponents? dateTimeComponents;
    if (task.isRepeating) {
      if (task.repeatInterval == s.daily) {
        dateTimeComponents = DateTimeComponents.time;
      } else if (task.repeatInterval == s.weekly) {
        dateTimeComponents = DateTimeComponents.dayOfWeekAndTime;
      } else if (task.repeatInterval == s.monthly) {
        dateTimeComponents = DateTimeComponents.dayOfMonthAndTime;
      } else if (task.repeatInterval == s.everyXDays(2)) { // This one won't repeat with DateTimeComponents
        dateTimeComponents = null;
      } else if (task.repeatInterval == s.weekdays) {
        dateTimeComponents = DateTimeComponents.dayOfWeekAndTime;
      } else if (task.repeatInterval == s.weekends) {
        dateTimeComponents = DateTimeComponents.dayOfWeekAndTime;
      }
    }

    await flutterLocalNotificationsPlugin.zonedSchedule(
      task.hashCode,
      s.appTitle,
      '${s.notificationReminderBody} ${task.title}',
      tzScheduleDateTime,
      notificationDetails,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      matchDateTimeComponents: dateTimeComponents,
      payload: 'task_id:${task.hashCode}',
    );

    developer.log("Notification scheduled for task '${task.title}' at $scheduleDateTime. Repeat: ${task.repeatInterval}", name: "Notifications");
  }


  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context)!;
    final List<String> repeatOptions = [
      s.noRepeat,
      s.daily,
      s.weekly,
      s.monthly,
      s.everyXDays(2),
      s.weekdays,
      s.weekends,
    ];
    final List<String> listOptions = [s.defaultList, s.personal, s.work, s.shopping];

    _selectedRepeatInterval ??= s.noRepeat;
    _selectedListName ??= s.defaultList;


    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? s.editTaskTitle : s.newTaskTitle),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            onPressed: () => _saveTask(s),
            tooltip: s.saveTask,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(s.whatIsToBeDone, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              controller: _titleController,
              decoration: InputDecoration(
                hintText: s.enterYourTaskHere,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
              style: Theme.of(context).textTheme.bodyLarge,
              minLines: 1,
              maxLines: 3,
            ),
            const SizedBox(height: 20),

            Text(s.dueDate, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ListTile(
              leading: Icon(Icons.calendar_today_outlined, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7)),
              title: Text(_selectedDate == null ? s.notSet : DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag()).format(_selectedDate!)),
              trailing: IconButton(
                icon: Icon(Icons.close, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7)),
                onPressed: () { setState(() { _selectedDate = null; if (_selectedTime == null) _notificationsEnabled = false; }); },
              ),
              onTap: () => _pickDate(s),
              tileColor: Theme.of(context).cardTheme.color,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16.0),
            ),
            const SizedBox(height: 10),

            Text(s.dueTime, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ListTile(
              leading: Icon(Icons.access_time, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7)),
              title: Text(_selectedTime == null ? s.notSet : MaterialLocalizations.of(context).formatTimeOfDay(_selectedTime!, alwaysUse24HourFormat: MediaQuery.of(context).alwaysUse24HourFormat)),
              trailing: IconButton(
                icon: Icon(Icons.close, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7)),
                onPressed: () { setState(() { _selectedTime = null; if (_selectedDate == null) _notificationsEnabled = false; }); },
              ),
              onTap: () => _pickTime(s),
              tileColor: Theme.of(context).cardTheme.color,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16.0),
            ),
            const SizedBox(height: 20),

            Text(s.notifications, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SwitchListTile(
              title: Text(s.enableNotifications),
              value: _notificationsEnabled,
              onChanged: (_selectedDate != null || _selectedTime != null) ? (bool value) {
                setState(() {
                  _notificationsEnabled = value;
                  if (!value) {
                    _selectedRepeatInterval = s.noRepeat;
                  }
                });
              } : null,
              tileColor: Theme.of(context).cardTheme.color,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16.0),
            ),
            const SizedBox(height: 20),

            Text(s.repeat, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _selectedRepeatInterval ?? s.noRepeat,
              decoration: InputDecoration(
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                filled: true,
                fillColor: Theme.of(context).cardTheme.color,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
              items: repeatOptions.map<DropdownMenuItem<String>>((String value) {
                return DropdownMenuItem<String>(
                  value: value,
                  child: Text(value, style: Theme.of(context).textTheme.bodyMedium),
                );
              }).toList(),
              onChanged: _notificationsEnabled ? (String? newValue) {
                setState(() {
                  _selectedRepeatInterval = newValue;
                });
              } : null,
            ),
            const SizedBox(height: 20),

            Text(s.addToLlist, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _selectedListName ?? s.defaultList,
              decoration: InputDecoration(
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                filled: true,
                fillColor: Theme.of(context).cardTheme.color,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
              items: listOptions.map<DropdownMenuItem<String>>((String value) {
                return DropdownMenuItem<String>(
                  value: value,
                  child: Text(value, style: Theme.of(context).textTheme.bodyMedium),
                );
              }).toList(),
              onChanged: (String? newValue) {
                setState(() {
                  _selectedListName = newValue;
                });
              },
            ),
            const SizedBox(height: 40),

            Center(
              child: ElevatedButton.icon(
                onPressed: () => _saveTask(s),
                icon: const Icon(Icons.check),
                label: Text(s.saveTask),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(200, 50),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}