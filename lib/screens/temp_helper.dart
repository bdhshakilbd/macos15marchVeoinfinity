
  Widget _buildMinimalDropdown<T>({
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.grey.shade300),
        color: Colors.white,
      ),
      height: 28,
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          items: items,
          onChanged: onChanged,
          isDense: true,
          style: const TextStyle(fontSize: 12, color: Colors.black87),
          icon: const Icon(Icons.keyboard_arrow_down, size: 16, color: Colors.grey),
          focusColor: Colors.transparent,
        ),
      ),
    );
  }
